// Log study 2026-10-28: the iPhone (436, 3:28 PM) and the Mac (435, 1:31 PM) drew a reply twice when the prompt came
// from the other device. Hermes stored the turn as 34560 prompt, 34561 tool call, 34562 result, 34563 tool call with
// thinking, 34564 result, 34565 reply. The history fold files that turn as one message under row 34563 (its first
// row with more than tool calls); the live end names 34565. The turn-end read matched the live bubble by row only and
// had no prompt bubble to scan from, so "live assistant row 34565 matched nothing" and both copies stayed for minutes.

import Foundation
import Testing
@testable import HermesHQNative

@Suite("A folded stored reply takes the place of its live bubble", .serialized)
@MainActor
struct FoldedReplyOtherDeviceTests {
    private static let reply = "I checked five past :60 radio spots. the host's portion runs roughly 136 to 154 words."

    private func call(_ id: String, _ command: String) -> JSONValue {
        ["id": .string(id), "type": "function",
         "function": ["name": "terminal", "arguments": .string("{\"command\": \"\(command)\"}")]]
    }

    private func before(_ now: Double) -> [JSONValue] {
        [["role": "user", "content": "How long is this script?", "row_id": 34556, "timestamp": .number(now - 300)],
         ["role": "assistant", "content": "It's 147 words, about 59 seconds.", "row_id": 34559, "finish_reason": "stop",
          "timestamp": .number(now - 290)]]
    }

    private func turn(_ now: Double, prompt: JSONValue) -> [JSONValue] {
        [prompt,
         ["role": "assistant", "content": "", "row_id": 34561, "timestamp": .number(now - 20), "tool_calls": [call("c1", "ls spots")]],
         ["role": "tool", "content": "{\"output\": \"5 files\"}", "row_id": 34562, "timestamp": .number(now - 19), "tool_call_id": "c1"],
         ["role": "assistant", "content": "", "reasoning": "Counting the host's words.", "row_id": 34563, "timestamp": .number(now - 15),
          "tool_calls": [call("c2", "wc -w spots")]],
         ["role": "tool", "content": "{\"output\": \"143\"}", "row_id": 34564, "timestamp": .number(now - 14), "tool_call_id": "c2"],
         ["role": "assistant", "content": .string(Self.reply), "row_id": 34565, "finish_reason": "stop", "timestamp": .number(now - 10)]]
    }

    private func copies(_ s: LiveChatSession) -> Int { s.messages.filter { $0.plainText.contains("five past :60") }.count }

    /// Opens on the earlier turn, plays a turn this device didn't send, then lets the turn-end read land the stored rows.
    private func run(prompt: (Double) -> JSONValue) async throws -> (Int, LiveChatSession) {
        let h = try ChatHarness()
        let now = Date().timeIntervalSince1970
        h.setPage("24", rows: before(now))
        h.setPage("1", rows: [before(now).last!])
        let s = h.make()
        #expect(await h.open())
        let runtime = try #require(s.runtimeSessionId)
        let stored = before(now) + turn(now, prompt: prompt(now))
        h.setPage("24", rows: stored)
        h.setPage("1", rows: [stored.last!])
        await h.emit([
            h.event("message.start", seq: 40, sid: runtime),
            h.event("message.delta", ["text": .string(Self.reply)], seq: 41, sid: runtime),
            h.event("message.complete", ["text": .string(Self.reply), "status": "complete",
                                         "persisted_turn": ["final_assistant_row_id": 34565]], seq: 42, sid: runtime),
        ])
        var worst = copies(s)
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(30))
            s.flushChanges()
            worst = max(worst, copies(s))
        }
        _ = await waitUntil { h.client.restLog.count >= 3 }
        try? await Task.sleep(for: .milliseconds(100))
        s.flushChanges()
        return (max(worst, copies(s)), s)
    }

    @Test func foldingFilesTheTurnUnderItsFirstTextRowAndKeepsItsLast() throws {
        let now = Date().timeIntervalSince1970
        let page = Hydration.fold(before(now) + turn(now, prompt: ["role": "user", "content": "Go look", "row_id": 34560,
                                                                 "timestamp": .number(now - 25)]), pageSeq: 1)
        let last = try #require(page.messages.last)
        #expect(last.rowId == 34563)
        #expect(page.meta[last.id]?.firstRowId == 34561)
        #expect(page.meta[last.id]?.lastRowId == 34565)
        #expect(TranscriptMerge.holds(last, page.meta[last.id], row: 34565))
        #expect(!TranscriptMerge.holds(last, page.meta[last.id], row: 34566))
        #expect(!TranscriptMerge.holds(page.messages[1], page.meta[page.messages[1].id], row: 34565))
    }

    /// The 3:28 PM merge, as logged: the phone came back with the first prompt (34556) on screen, the reconnect's replay
    /// drew both turns' replies live (34559, then 34565 for a prompt it never showed), and the tail read matched the first
    /// by row but the second to nothing: its prompt scan stops at 34560, after the reply the first bubble already holds.
    @Test func theTailReadAfterAReplayMatchesTheFoldedReply() throws {
        let now = Date().timeIntervalSince1970
        let page = Hydration.fold(before(now) + turn(now, prompt: ["role": "user", "content": "Go look", "row_id": 34560,
                                                                 "timestamp": .number(now - 25)]), pageSeq: 1)
        #expect(page.messages.map(\.id) == ["stored-row-34556-user", "stored-row-34559-assistant", "stored-row-34560-user",
                                            "stored-row-34563-assistant"])
        let first = ChatMessage(id: "local-assistant-7", role: .assistant, parts: [.text("It's 147 words, about 59 seconds.")],
                                timestamp: nil, rowId: 34559)
        let second = ChatMessage(id: "local-assistant-8", role: .assistant, parts: [.text(Self.reply)], timestamp: nil, rowId: 34565)
        let shown = [page.messages[0], first, second]
        let graft = TranscriptMerge.graft(fresh: page.messages, freshMeta: page.meta, onto: shown, previousMeta: page.meta,
                                          aliases: [:], replaceAll: false)
        #expect(graft.messages.map(\.id) == ["stored-row-34556-user", "local-assistant-7", "stored-row-34560-user", "local-assistant-8"])
        #expect(graft.aliases["stored-row-34563-assistant"] == "local-assistant-8")
        #expect(graft.messages.filter { $0.plainText.contains("five past :60") }.count == 1)
    }

    /// Owner 2026-10-29 (build 475, Hermes "To Inbox"): the turn's tool steps were heard in one live bubble, the phone
    /// left, and on return its reply came as a second live bubble carrying the final row. The tail read gave the folded
    /// stored message to the first bubble and kept the second as unstored, so the reply showed twice until a reopen.
    @Test func aSecondLiveBubbleOfTheSameTurnGoes() throws {
        let now = Date().timeIntervalSince1970
        let page = Hydration.fold(before(now) + turn(now, prompt: ["role": "user", "content": "Go look", "row_id": 34560,
                                                                 "timestamp": .number(now - 25)]), pageSeq: 1)
        let prompt = ChatMessage(id: "local-user-3", role: .user, parts: [.text("Go look")], timestamp: nil, rowId: 34560)
        let steps = ChatMessage(id: "local-assistant-7", role: .assistant,
                                parts: [.tool(ToolCall(id: "c1", name: "terminal", title: "Ran ls spots", argsText: nil, summary: "5 files", state: .done))], timestamp: nil, rowId: nil)
        let reply = ChatMessage(id: "local-assistant-8", role: .assistant, parts: [.text(Self.reply)], timestamp: nil, rowId: 34565)
        let shown = Array(page.messages[..<2]) + [prompt, steps, reply]
        let first = TranscriptMerge.graft(fresh: page.messages, freshMeta: page.meta, onto: shown, previousMeta: page.meta,
                                          aliases: [:], replaceAll: false)
        #expect(first.messages.map(\.id) == ["stored-row-34556-user", "stored-row-34559-assistant", "local-user-3", "local-assistant-7"])
        #expect(first.messages.filter { $0.plainText.contains("five past :60") }.count == 1)
        // The read after it, with the first bubble already holding the stored message, keeps it at one too.
        let again = TranscriptMerge.graft(fresh: page.messages, freshMeta: page.meta, onto: shown, previousMeta: page.meta,
                                          aliases: ["stored-row-34563-assistant": "local-assistant-7", "stored-row-34560-user": "local-user-3"],
                                          replaceAll: false)
        #expect(again.messages.filter { $0.plainText.contains("five past :60") }.count == 1)
    }

    @Test func aPromptFromTheOtherDevice() async throws {
        let (worst, s) = try await run { now in
            ["role": "user", "content": "Need about 10 seconds for the announcer. Go look at past spots.", "row_id": 34560,
             "timestamp": .number(now - 25)]
        }
        #expect(copies(s) == 1, "reply shown \(copies(s))× after the turn-end read (worst \(worst))")
        #expect(s.messages.filter { $0.role == .assistant }.count == 2)    // the earlier reply and this one
    }

    @Test func aTurnStartedByABackgroundResult() async throws {
        let (worst, s) = try await run { now in
            ["role": "user", "content": "[ASYNC DELEGATION BATCH COMPLETE — deleg_1] 1 subagent finished.", "row_id": 34560,
             "timestamp": .number(now - 25), "display_kind": "async_delegation_complete",
             "display_metadata": ["display_text": "Subagent Task Completed: past spots"]]
        }
        #expect(copies(s) == 1, "reply shown \(copies(s))× after the turn-end read (worst \(worst))")
        #expect(s.messages.filter { $0.role == .assistant }.count == 2)    // the earlier reply and this one
    }

    @Test func storedCopyOnScreenFirstThenTheTurnsEnd() async throws {
        // The read lands before the frames (a chat opened from the alert): the end's row is inside the shown message.
        let h = try ChatHarness()
        let now = Date().timeIntervalSince1970
        let stored = before(now) + turn(now, prompt: ["role": "user", "content": "Go look", "row_id": 34560, "timestamp": .number(now - 25)])
        h.setPage("24", rows: stored)
        h.setPage("1", rows: [stored.last!])
        let s = h.make()
        s.turnEndReadDelay = .seconds(30)
        #expect(await h.open())
        #expect(copies(s) == 1)
        let runtime = try #require(s.runtimeSessionId)
        await h.emit([
            h.event("message.start", seq: 40, sid: runtime),
            h.event("message.delta", ["text": .string(Self.reply)], seq: 41, sid: runtime),
            h.event("message.complete", ["text": .string(Self.reply), "status": "complete",
                                         "persisted_turn": ["final_assistant_row_id": 34565]], seq: 42, sid: runtime),
        ])
        #expect(copies(s) == 1, "reply shown \(copies(s))×")
    }
}
