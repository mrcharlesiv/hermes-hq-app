// [foreign-prompt] Owner 2026-11-03: a voice memo sent from the iPhone never showed on the Mac, open on the same chat,
// while Hermes worked on it (logs: "a turn this phone didn't send", then nothing until the turn's end). Hermes stores
// the prompt as the turn starts (row 48039 at 08:48:43, the start's own second), so the chat reads it then.

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Another device's prompt shows as its turn starts", .serialized)
@MainActor
struct ForeignPromptShowsTests {
    private static let prompt = "Your Mac studio is almost out of storage. Figure out what is using it."
    private static let reply = "Most of it is old simulators."

    private func before(_ now: Double) -> [JSONValue] {
        [["role": "user", "content": "How is the disk?", "row_id": 100, "timestamp": .number(now - 300)],
         ["role": "assistant", "content": "Fine for now.", "row_id": 101, "finish_reason": "stop", "timestamp": .number(now - 290)]]
    }

    private func prompts(_ s: LiveChatSession) -> Int { s.messages.filter { $0.role == .user && $0.plainText.contains("almost out of storage") }.count }
    private func replies(_ s: LiveChatSession) -> Int { s.messages.filter { $0.plainText.contains("old simulators") }.count }

    @Test func thePromptShowsWhileTheTurnRunsAndOnceAfter() async throws {
        let h = try ChatHarness()
        let now = Date().timeIntervalSince1970
        h.setPage("24", rows: before(now))
        h.setPage("1", rows: [before(now).last!])
        let s = h.make()
        s.foreignPromptReadDelay = .milliseconds(50)
        s.turnEndReadDelay = .milliseconds(100)
        #expect(await h.open())
        let runtime = try #require(s.runtimeSessionId)
        // The other device's prompt is stored as its turn starts.
        let prompt: JSONValue = ["role": "user", "content": .string(Self.prompt), "row_id": 102, "timestamp": .number(now - 5)]
        h.setPage("24", rows: before(now) + [prompt])
        h.setPage("1", rows: [prompt])
        await h.emit([h.event("message.start", seq: 40, sid: runtime)])
        #expect(await waitUntil { s.flushChanges(); return prompts(s) == 1 }, "the prompt never showed while the turn ran")
        #expect(s.turn.busy)
        // The reply streams on below it, and the turn-end read keeps one of each.
        let answer: JSONValue = ["role": "assistant", "content": .string(Self.reply), "row_id": 103, "finish_reason": "stop",
                                 "timestamp": .number(now - 1)]
        h.setPage("24", rows: before(now) + [prompt, answer])
        h.setPage("1", rows: [answer])
        await h.emit([
            h.event("message.delta", ["text": .string(Self.reply)], seq: 41, sid: runtime),
            h.event("message.complete", ["text": .string(Self.reply), "status": "complete",
                                         "persisted_turn": ["final_assistant_row_id": 103]], seq: 42, sid: runtime),
        ])
        try? await Task.sleep(for: .milliseconds(600))
        s.flushChanges()
        #expect(prompts(s) == 1)
        #expect(replies(s) == 1)
        let users = s.messages.indices.filter { s.messages[$0].role == .user }
        let replyAt = try #require(s.messages.firstIndex { $0.plainText.contains("old simulators") })
        #expect(users.last.map { $0 < replyAt } == true, "the reply should sit under its prompt")
    }
}
