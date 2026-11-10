// Owner 2026-10-26 8:02 PM, "App" bot: "How many Mac installs?" sent a subagent off; its "Subagent Task Completed" row
// started a turn the phone didn't send. The alert was tapped, the first page already held that turn's reply (row 6155),
// then the turn's own frames landed (message.start … message.complete row 6155) and drew the reply a second time,
// until the next read. Hermes stored it once. Diagnostic line: "stored-row-6155-assistant row 6155 + local-assistant-1
// row 6155; after first page 23 rows > graft running false > message.start > complete row 6155".

import Foundation
import Testing
@testable import HermesHQNative

@Suite("A turn's frames for a reply already on screen don't draw it again", .serialized)
@MainActor
struct ReplyAlreadyShownTests {
    private static let reply = "I can't verify a Mac install count yet. The Mac app is downloaded directly from the website, separate from TestFlight."

    private func page(_ now: Double, prompt: Bool = false) -> [JSONValue] {
        var rows: [JSONValue] = [
            ["role": "user", "content": "How many Mac installs?", "row_id": 6104, "timestamp": .number(now - 140)],
            ["role": "assistant", "content": "I'm checking the Mac download hosting and update records separately.", "row_id": 6108,
             "finish_reason": "stop", "timestamp": .number(now - 130)],
            ["role": "user", "content": "[ASYNC DELEGATION BATCH COMPLETE — deleg_2dabd46b] A background fan-out unit you dispatched earlier — 1 subagent finished.",
             "row_id": 6154, "timestamp": .number(now - 10), "display_kind": "async_delegation_complete",
             "display_metadata": ["display_text": "Subagent Task Completed: How many Mac installs"]],
            ["role": "assistant", "content": .string(Self.reply), "row_id": 6155, "finish_reason": "stop", "timestamp": .number(now - 7)],
        ]
        if prompt { rows.append(["role": "user", "content": "Thanks", "row_id": 6160, "timestamp": .number(now - 2)]) }
        return rows
    }

    private func copies(_ s: LiveChatSession) -> Int { s.messages.filter { $0.plainText.contains("verify a Mac install") }.count }

    /// Opens on a page that holds the reply, then plays the turn's frames, each delivery as one batch (a catch-up hands
    /// its frames over together, so the screen sees the batch's end); returns the most copies seen at any flush.
    private func run(_ deliveries: (ChatHarness, String) -> [[JSONValue]], prompt: Bool = false) async throws -> (Int, LiveChatSession) {
        let h = try ChatHarness()
        let rows = page(Date().timeIntervalSince1970, prompt: prompt)
        h.setPage("24", rows: rows)
        h.setPage("1", rows: [rows.last!])
        let s = h.make()
        s.turnEndReadDelay = .seconds(30)   // the 8:02 PM turn-end read took 15 s: what the frames draw is what is judged
        #expect(await h.open())
        #expect(copies(s) == 1)
        let runtime = try #require(s.runtimeSessionId)
        var worst = 0
        for batch in deliveries(h, runtime) {
            await h.emit(batch)
            worst = max(worst, copies(s))
        }
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(30))
            s.flushChanges()
            worst = max(worst, copies(s))
        }
        return (worst, s)
    }

    @Test func aStreamedTurnWhoseReplyTheFirstPageHeld() async throws {
        let (worst, s) = try await run { h, rid in [[
            h.event("message.start", seq: 40, sid: rid),
            h.event("message.delta", ["text": .string(Self.reply)], seq: 41, sid: rid),
            h.event("message.complete", ["text": .string(Self.reply), "status": "complete",
                                         "persisted_turn": ["final_assistant_row_id": 6155]], seq: 42, sid: rid),
        ]] }
        #expect(worst == 1, "reply shown \(worst)×")
        #expect(!s.isRunning)
        #expect(s.messages.last?.rowId == 6155)
    }

    @Test func aBareTurnEndForAReplyAlreadyShown() async throws {
        // An end with no deltas (a replayed tail, an open request's late answer): no bubble of its own either.
        let (worst, _) = try await run { h, rid in [[
            h.event("message.start", seq: 40, sid: rid),
            h.event("message.complete", ["text": .string(Self.reply), "status": "complete", "row_id": 6155], seq: 41, sid: rid),
        ]] }
        #expect(worst == 1, "reply shown \(worst)×")
    }

    @Test func aTurnEndForAReplyAboveANewerPrompt() async throws {
        // The reply is on screen above a newer prompt (the reader answered before the frames came): still drawn once.
        let (worst, _) = try await run({ h, rid in [[
            h.event("message.start", seq: 40, sid: rid),
            h.event("message.delta", ["text": .string(Self.reply)], seq: 41, sid: rid),
            h.event("message.complete", ["text": .string(Self.reply), "status": "complete", "row_id": 6155], seq: 42, sid: rid),
        ]] }, prompt: true)
        #expect(worst == 1, "reply shown \(worst)×")
    }

    @Test func aTurnEndDeliveredAgain() async throws {
        // The same end twice (a replay after a reconnect under a new epoch, so seq doesn't drop it): one copy.
        let (worst, s) = try await run { h, rid in [[
            h.event("message.start", seq: 40, sid: rid),
            h.event("message.delta", ["text": .string(Self.reply)], seq: 41, sid: rid),
            h.event("message.complete", ["text": .string(Self.reply), "status": "complete", "row_id": 6155], seq: 42, sid: rid),
        ], [
            h.event("message.start", sid: rid),
            h.event("message.delta", ["text": .string(Self.reply)], sid: rid),
            h.event("message.complete", ["text": .string(Self.reply), "status": "complete", "row_id": 6155], sid: rid),
        ]] }
        #expect(worst == 1, "reply shown \(worst)×")
        #expect(!s.isRunning)
    }

    @Test func aNewReplyStillShows() async throws {
        // Control: a turn end naming a row that isn't on screen keeps its live bubble.
        let (_, s) = try await run { h, rid in [[
            h.event("message.start", seq: 40, sid: rid),
            h.event("message.delta", ["text": "A different answer."], seq: 41, sid: rid),
            h.event("message.complete", ["text": "A different answer.", "status": "complete", "row_id": 6170], seq: 42, sid: rid),
        ]] }
        #expect(s.messages.contains { $0.plainText == "A different answer." })
        #expect(copies(s) == 1)
    }
}
