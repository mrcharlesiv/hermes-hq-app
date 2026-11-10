// Owner 2026-10-23, Hermes chat: a voice memo sent, the link dropped 43 s into the turn (tools running), the reply finished
// 34 s later while the phone was away, and the phone came back 9 s after that. The reply showed twice, then once.
// Hermes stored it once (rows 26893–26902: the prompt, four tool-call rows with their tool rows, the reply).

import Foundation
import Testing
@testable import HermesHQNative

@Suite("A reply that finished while the link was down shows once", .serialized)
@MainActor
struct AwayMidTurnTests {
    private static let ready: JSONValue = ["heartbeat": true, "change_events": true, "replay_epoch": "fixture-epoch"]
    private static let reply = "The short version: the domain is old, but the company is new."

    enum Return { case restRead, emptyReplay, replayedEnd }

    private func storedTurn(_ now: Double, prompt: String) -> [JSONValue] {
        var rows: [JSONValue] = [["role": "user", "content": .string(prompt), "row_id": 8000, "timestamp": .number(now - 80)]]
        for k in 0..<4 {
            let id = "c\(k)"
            rows.append(["role": "assistant", "content": "", "row_id": .number(Double(8001 + 2 * k)), "timestamp": .number(now - 76 + Double(k * 10)),
                         "finish_reason": "tool_calls",
                         "tool_calls": [["id": .string(id), "type": "function", "function": ["name": "terminal", "arguments": "{\"command\":\"whois\"}"]]]])
            rows.append(["role": "tool", "content": "{\"output\":\"ok\",\"exit_code\":0}", "tool_call_id": .string(id),
                         "row_id": .number(Double(8002 + 2 * k)), "timestamp": .number(now - 75 + Double(k * 10))])
        }
        rows.append(["role": "assistant", "content": .string(Self.reply), "row_id": 8009, "finish_reason": "stop", "timestamp": .number(now - 10)])
        return rows
    }

    private func run(_ way: Return, prompt: String = "Look up this domain", ackRow: Bool = true, readWhileBusy: Bool = false) async throws -> [ChatMessage] {
        let h = try ChatHarness(ready: Self.ready)
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        h.client.onCall { method, _ in method == "prompt.submit" ? (ackRow ? ["status": "streaming", "user_row_id": 8000] : ["status": "streaming"]) : [:] }
        s.send(prompt)
        #expect(await waitUntil { h.lastUser?.isPending == false })
        let runtime = try #require(s.runtimeSessionId)
        await h.emit([h.event("message.start", seq: 8, sid: runtime),
                      h.event("tool.start", ["tool_id": "c0", "name": "terminal", "args": ["command": "whois"]], seq: 9, sid: runtime),
                      h.event("tool.complete", ["tool_id": "c0", "name": "terminal", "result": ["stdout": "ok", "exit_code": 0]], seq: 10, sid: runtime),
                      h.event("tool.start", ["tool_id": "c1", "name": "terminal", "args": ["command": "whois"]], seq: 11, sid: runtime)])
        #expect(s.isRunning)
        let now = Date().timeIntervalSince1970
        let base = Array((try ChatFixtures.json("perf-page-latest-24.json")["messages"]?.array ?? []).suffix(14))
        let page = base + storedTurn(now, prompt: prompt)
        h.setPage("24", rows: page, hasMore: true)
        h.setPage("120", rows: page, hasMore: true)
        h.setPage("1", rows: [page.last!], hasMore: true)
        let missed: [JSONValue] = [
            ["type": "tool.complete", "session_id": .string(runtime), "seq": 12, "payload": ["tool_id": "c1", "name": "terminal", "result": ["stdout": "ok", "exit_code": 0]]],
            ["type": "message.delta", "session_id": .string(runtime), "seq": 13, "payload": ["text": .string(Self.reply)]],
            ["type": "message.complete", "session_id": .string(runtime), "seq": 14,
             "payload": ["text": .string(Self.reply), "status": "complete", "final_assistant_row_id": 8009]],
        ]
        if readWhileBusy {
            // The alert tapped, or the look-again read, while the chat still takes the turn for running.
            let before = h.client.restLog.count
            s.probeTailSoon(after: .zero, force: true)
            #expect(await waitUntil { h.client.restLog.count > before && s.refreshTask == nil })
            s.flushChanges()
            #expect(s.messages.filter { $0.plainText.contains("domain is old") }.count <= 1)
        }
        h.client.onCall { method, _ in
            switch method {
            case "session.activate": return ["session_id": .string(runtime), "running": false]
            case "session.events.since":
                switch way {
                case .restRead: return ["events": [], "latest_seq": 99, "truncated": true, "epoch": "fixture-epoch"]
                case .emptyReplay: return ["events": [], "latest_seq": 11, "truncated": false, "epoch": "fixture-epoch"]
                case .replayedEnd: return ["events": .array(missed), "latest_seq": 14, "truncated": false, "epoch": "fixture-epoch"]
                }
            case "session.active_list": return ["sessions": []]
            default: return [:]
            }
        }
        h.client.setConnection(.reconnecting(attempt: 1))
        h.client.setConnection(.ready)
        h.client.setReady(Self.ready)
        #expect(await waitUntil(timeout: .seconds(3)) { !h.client.calls("session.activate").isEmpty && !s.parking })
        var snapshots: [[String]] = []
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(100))
            s.flushChanges()
            snapshots.append(s.messages.map(\.plainText))
        }
        let worst = snapshots.map { $0.filter { $0.contains("domain is old") }.count }.max() ?? 0
        #expect(worst == 1, "reply shown \(worst)× at some point (\(way))")
        #expect(!s.isRunning)
        return s.messages
    }

    @Test func restReadAfterReturn() async throws { _ = try await run(.restRead) }
    @Test func emptyReplayAfterReturn() async throws { _ = try await run(.emptyReplay) }
    @Test func replayedTurnEndAfterReturn() async throws { _ = try await run(.replayedEnd) }

    private static let memo = "MEDIA:\"/Users/x/.hermes/attachments/voice-memo-166.m4a\"\n\nVoice memo transcript: Go look up the history of this domain."
    @Test func memoPromptRestRead() async throws { _ = try await run(.restRead, prompt: Self.memo) }
    @Test func memoPromptNoAckRowRestRead() async throws { _ = try await run(.restRead, prompt: Self.memo, ackRow: false) }
    @Test func memoPromptNoAckRowReplayedEnd() async throws { _ = try await run(.replayedEnd, prompt: Self.memo, ackRow: false) }
    @Test func readWhileBusyThenRestRead() async throws { _ = try await run(.restRead, readWhileBusy: true) }
    @Test func readWhileBusyThenReplayedEnd() async throws { _ = try await run(.replayedEnd, readWhileBusy: true) }
    @Test func memoReadWhileBusyNoAckRow() async throws { _ = try await run(.emptyReplay, prompt: Self.memo, ackRow: false, readWhileBusy: true) }

    // MARK: The doubled-reply watch (diagnostic only)

    private func reply(_ id: String, _ text: String, row: Int?) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, parts: [.text(text)], timestamp: Date(), rowId: row)
    }

    @Test func theWatchSeesALiveCopyBesideItsStoredReply() {
        let live = reply("local-assistant-3", Self.reply, row: nil)
        let stored = reply("stored-row-8009-assistant", Self.reply, row: 8009)
        #expect(LiveChatSession.doubledReply(in: [stored, live][...])?.1.id == "local-assistant-3")
        // Two stored rows of their own: the bot said it twice. Short replies ("OK") are not judged.
        #expect(LiveChatSession.doubledReply(in: [stored, reply("stored-row-8020-assistant", Self.reply, row: 8020)][...]) == nil)
        #expect(LiveChatSession.doubledReply(in: [reply("local-a", "OK", row: nil), reply("local-b", "OK", row: nil)][...]) == nil)
        #expect(LiveChatSession.doubledReply(in: [stored, reply("stored-copy", Self.reply, row: 8009)][...]) != nil)
    }

    @Test func aNewReplyThatOpensLikeTheLastIsNotACopy() {
        // Log study 2026-10-28 (Mac 3:31 PM): the next reply, still streaming, began with the last one's words.
        let opening = "Here is the tightened :60 script for the host, with the announcer's ten seconds at the end. "
        let last = reply("stored-row-34569-assistant", opening + String(repeating: "Line of the script. ", count: 45), row: 34569)
        let streaming = reply("local-assistant-12", opening + "Line", row: nil)
        #expect(LiveChatSession.doubledReply(in: [last, streaming][...]) == nil)
        // Once it is as long, the same words are a copy again.
        #expect(LiveChatSession.doubledReply(in: [last, reply("local-assistant-12", last.plainText, row: nil)][...]) != nil)
    }

    @Test func aDoubledReplyIsLoggedWithItsStepsThenItsEnd() async throws {
        let h = try ChatHarness(ready: Self.ready)
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        s.noteCatchUp("reconnect test")
        s.appendMessage(reply("stored-row-9001-assistant", Self.reply, row: 9001))
        s.appendMessage(reply("local-assistant-99", Self.reply, row: nil))
        s.flushChanges()
        DiagnosticLog.shared.flush()
        #expect(DiagnosticLog.shared.tail().contains("doubled reply: \(AppLog.tag("stored-row-9001-assistant")) row 9001"))
        #expect(DiagnosticLog.shared.tail().contains("\(AppLog.tag("local-assistant-99")) row - len"))
        #expect(DiagnosticLog.shared.tail().contains("reconnect test"))
        s.messages.removeLast()
        s.changes.markState()
        s.flushChanges()
        DiagnosticLog.shared.flush()
        #expect(DiagnosticLog.shared.tail().contains("doubled reply gone; after"))
    }
}
