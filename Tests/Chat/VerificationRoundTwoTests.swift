import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

/// A stored chat the fake gateway pages like Hermes does (`order=latest`: `offset` rows back from the newest end).
nonisolated final class RowBackend: Sendable {
    let rows = Mutex<[JSONValue]>([])
    let reads = Mutex<[String]>([])

    func set(_ new: [JSONValue]) { rows.withLock { $0 = new } }
    func append(_ more: [JSONValue]) { rows.withLock { $0 += more } }

    func answer(stored: String, query: [URLQueryItem]) -> Data {
        let limit = Int(query.first { $0.name == "limit" }?.value ?? "500") ?? 500
        let offset = Int(query.first { $0.name == "offset" }?.value ?? "0") ?? 0
        reads.withLock { $0.append(offset > 0 ? "\(limit)@\(offset)" : "\(limit)") }
        let all = rows.withLock { $0 }
        let end = max(0, all.count - offset)
        let start = max(0, end - limit)
        let page = Array(all[start..<end])
        let body: JSONValue = ["session_id": .string(stored), "profile": "default", "messages": .array(page),
                               "pagination": ["limit": .number(Double(limit)), "offset": .number(Double(offset)),
                                              "order": "latest", "returned": .number(Double(page.count)),
                                              "has_more": .bool(start > 0)]]
        return encodeJSON(body)
    }

    /// One long tool turn: the prompt, `tools` × (call row + result row), then the final reply. Rows from `firstRow` up.
    static func toolTurn(prompt: String, tools: Int, reply: String, firstRow: Int, ts: Double = 1791590000) -> [JSONValue] {
        var out: [JSONValue] = [["role": "user", "content": .string(prompt), "row_id": .number(Double(firstRow)), "timestamp": .number(ts)]]
        var row = firstRow + 1
        for k in 0..<tools {
            let id = "call-\(firstRow)-\(k)"
            out.append(["role": "assistant", "content": "", "row_id": .number(Double(row)), "timestamp": .number(ts + Double(row)),
                        "tool_calls": [["id": .string(id), "type": "function",
                                        "function": ["name": "terminal", "arguments": .string("{\"command\":\"step \(k)\"}")]]]])
            row += 1
            out.append(["role": "tool", "content": "{\"stdout\":\"ok\",\"exit_code\":0}", "tool_call_id": .string(id),
                        "row_id": .number(Double(row)), "timestamp": .number(ts + Double(row))])
            row += 1
        }
        out.append(["role": "assistant", "content": .string(reply), "row_id": .number(Double(row)), "timestamp": .number(ts + Double(row))])
        return out
    }

    static func chat(_ pairs: Int, firstRow: Int = 1) -> [JSONValue] {
        (0..<pairs).flatMap { k -> [JSONValue] in
            let row = Double(firstRow + 2 * k)
            return [["role": "user", "content": .string("question \(k)"), "row_id": .number(row), "timestamp": .number(1791500000 + row)],
                    ["role": "assistant", "content": .string("answer \(k)"), "row_id": .number(row + 1), "timestamp": .number(1791500000 + row + 1)]]
        }
    }
}

private func tools(_ m: ChatMessage) -> [ToolCall] {
    m.parts.compactMap { if case .tool(let c) = $0 { return c } else { return nil } }
}

@Suite("Verification round 2 (protocol)", .serialized)
@MainActor
struct VerificationRoundTwoTests {
    private func harness(_ backend: RowBackend) throws -> ChatHarness {
        let h = try ChatHarness()
        let stored = h.stored
        h.client.onRest { _, query in backend.answer(stored: stored, query: query) }
        return h
    }

    /// Drives one live turn of `toolCount` tool calls on `h`, appending its stored rows to `backend` as Hermes would.
    private func runToolTurn(_ h: ChatHarness, backend: RowBackend, prompt: String, toolCount: Int, reply: String) async throws {
        let s = h.session!
        let firstRow = (backend.rows.withLock { $0.last.flatMap(HistoryPage.rowId) } ?? 0) + 1
        let resume = try ChatFixtures.json("perf-resume.json")["result"] ?? .null
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ["status": "streaming", "user_row_id": .number(Double(firstRow))]
            case "session.resume", "session.activate": return resume
            case "session.active_list": return ["sessions": []]
            default: return [:]
            }
        }
        s.send(prompt)
        #expect(await waitUntil { h.lastUser?.isPending == false })
        var frames: [JSONValue] = [h.event("message.start")]
        for k in 0..<toolCount {
            let id = "call-\(firstRow)-\(k)"
            frames.append(h.event("tool.start", ["tool_id": .string(id), "name": "terminal", "args": ["command": .string("step \(k)")]]))
            frames.append(h.event("tool.complete", ["tool_id": .string(id), "name": "terminal", "result": ["stdout": "ok", "exit_code": 0]]))
        }
        frames.append(h.event("message.delta", ["text": .string(reply)]))
        let stored = RowBackend.toolTurn(prompt: prompt, tools: toolCount, reply: reply, firstRow: firstRow)
        let finalRow = HistoryPage.rowId(stored.last!)!
        backend.append(stored)
        frames.append(h.event("message.complete", ["text": .string(reply), "status": "complete",
                                                   "persisted_turn": ["user_row_id": .number(Double(firstRow)),
                                                                      "final_assistant_row_id": .number(Double(finalRow))]]))
        await h.emit(frames)
    }

    /// Blocker: a turn of ~141 stored rows ended with the reply shown twice, the stored copy above your own message
    /// (the end-of-turn read stopped at 120 rows, short of the turn's prompt).
    @Test func aLongToolTurnShowsOnceUnderItsPrompt() async throws {
        let backend = RowBackend()
        backend.set(RowBackend.chat(1))
        let h = try harness(backend)
        let s = h.make()
        #expect(await h.open())
        try await runToolTurn(h, backend: backend, prompt: "Run seventy steps", toolCount: 70, reply: "All seventy steps are done.")
        // The turn-end read lands.
        #expect(await waitUntil(timeout: .seconds(5)) { s.lastTurnEndReadAt != nil && s.refreshTask == nil })
        s.flushChanges()
        let roles = s.messages.map(\.role)
        #expect(roles == [.user, .assistant, .user, .assistant])
        #expect(s.messages.filter { $0.plainText.contains("All seventy steps are done.") }.count == 1)
        let reply = try #require(s.messages.last)
        #expect(tools(reply).count == 70)
        #expect(s.messages[2].plainText == "Run seventy steps")
        // It read back far enough to reach the prompt.
        #expect(backend.reads.withLock { $0 }.contains { $0.hasPrefix("121@") })
    }

    /// Same, with 300 rows of history before the turn, and a tool-only message in that history (no row id of its own):
    /// the history must stay (the Plaid turn shrank the chat to three messages).
    @Test func aLongToolTurnAfterHistoryKeepsTheHistory() async throws {
        let backend = RowBackend()
        var rows = RowBackend.chat(149)                      // rows 1…298
        // A reply that ran a tool and wrote no text (folds to a tool-only message), then one more exchange.
        rows.append(["role": "assistant", "content": "", "row_id": 299, "timestamp": 1791500299,
                     "tool_calls": [["id": "lone", "type": "function", "function": ["name": "terminal", "arguments": "{\"command\":\"ls\"}"]]]])
        rows.append(["role": "tool", "content": "{\"stdout\":\"a\",\"exit_code\":0}", "tool_call_id": "lone", "row_id": 300, "timestamp": 1791500300])
        backend.set(rows)
        let h = try harness(backend)
        let s = h.make()
        #expect(await h.open())
        #expect(await waitUntil { s.olderTask == nil })
        let before = s.messages.count
        #expect(before > 50)
        try await runToolTurn(h, backend: backend, prompt: "Long turn two", toolCount: 76, reply: "Done with the long turn.")
        #expect(await waitUntil(timeout: .seconds(5)) { s.lastTurnEndReadAt != nil && s.refreshTask == nil })
        s.flushChanges()
        #expect(s.messages.count == before + 2)
        #expect(s.messages.filter { $0.plainText.contains("Done with the long turn.") }.count == 1)
        #expect(s.messages[s.messages.count - 2].plainText == "Long turn two")
        #expect(tools(s.messages.last!).count == 76)
    }

    /// Opening the chat in the middle of a long turn showed the turn's stored tool rows above a second copy of its
    /// prompt, and the reply twice once it ended (Plaid p70/p71).
    @Test func openingMidLongTurnFoldsItUnderItsPrompt() async throws {
        let backend = RowBackend()
        var turn = RowBackend.toolTurn(prompt: "Long turn", tools: 70, reply: "Finished.", firstRow: 3)
        let finalRow = turn.removeLast()                          // still running: no reply row yet
        backend.set(RowBackend.chat(1) + turn)
        let h = try harness(backend)
        var resume = try ChatFixtures.json("perf-resume.json")["result"]?.object ?? [:]
        resume["running"] = true
        resume["status"] = "working"
        resume["inflight"] = ["user": "Long turn", "assistant": "", "status": "running"]
        let running = JSONValue.object(resume)
        let finished = Mutex(false)
        let idle = try ChatFixtures.json("perf-resume.json")["result"] ?? .null
        h.client.onCall { method, _ in
            switch method {
            case "session.resume", "session.activate": return finished.withLock { $0 } ? idle : running
            case "session.active_list": return ["sessions": [["id": "5cc537d1", "status": "working"]]]
            default: return [:]
            }
        }
        let s = h.make()
        #expect(await h.open())
        s.flushChanges()
        // The prompt shows once, above the running turn.
        #expect(s.messages.filter { $0.role == .user && $0.plainText == "Long turn" }.count == 1)
        let prompt = try #require(s.messages.lastIndex { $0.role == .user })
        #expect(s.messages[prompt].plainText == "Long turn")
        #expect(s.messages[(prompt + 1)...].allSatisfy { $0.role == .assistant })
        #expect(s.isRunning)
        // The turn ends.
        backend.append([finalRow])
        finished.withLock { $0 = true }
        await h.emit([h.event("message.delta", ["text": "Finished."]),
                      h.event("message.complete", ["text": "Finished.", "status": "complete",
                                                   "persisted_turn": ["user_row_id": 3, "final_assistant_row_id": .number(Double(HistoryPage.rowId(finalRow)!))]])])
        #expect(await waitUntil(timeout: .seconds(5)) { s.lastTurnEndReadAt != nil && s.refreshTask == nil })
        s.flushChanges()
        #expect(s.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(s.messages.filter { $0.plainText.contains("Finished.") }.count == 1)
        #expect(tools(s.messages.last!).count == 70)
    }

    /// Minor: after a reconnect where the connection's own replay found nothing missed, the chat asked
    /// `session.events.since` a second time with the same cursor.
    @Test func anEmptyReplayIsNotAskedTwice() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        await h.emit([h.event("session.info", ["running": false], seq: 43)])
        #expect(s.lastSeq == 43)
        let rid = try #require(s.runtimeSessionId)
        // The connection replayed this session from 43 and found nothing.
        h.client.setReplayed(rid, from: 43)
        h.client.setReady(["heartbeat": true, "change_events": true, "replay_epoch": "fixture-epoch"])
        #expect(await waitUntil { h.client.calls("session.activate").count == 1 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.client.calls("session.events.since").isEmpty)
        // Without a full replay of the session the chat still asks.
        h.client.setReplayed(rid, from: nil)
        h.client.setReady(["heartbeat": true, "change_events": true, "replay_epoch": "fixture-epoch"])
        #expect(await waitUntil { h.client.calls("session.events.since").count == 1 })
    }

    /// After Stop, the partial reply on screen vanished once history was re-read (the stand-in stores no partial text).
    @Test func stopKeepsTheWordsAlreadyShownWhenTheStoredTurnHasNone() async throws {
        let backend = RowBackend()
        backend.set(RowBackend.chat(1))
        let h = try harness(backend)
        let s = h.make()
        #expect(await h.open())
        let resume = try ChatFixtures.json("perf-resume.json")["result"] ?? .null
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ["status": "streaming", "user_row_id": 3]
            case "session.resume", "session.activate": return resume
            case "session.interrupt": return ["status": "interrupted"]
            default: return [:]
            }
        }
        s.send("Do three things")
        #expect(await waitUntil { h.lastUser?.isPending == false })
        var frames: [JSONValue] = [h.event("message.start"), h.event("message.delta", ["text": "Working on the first part now. "])]
        for k in 0..<3 {
            frames.append(h.event("tool.start", ["tool_id": .string("call-3-\(k)"), "name": "terminal", "args": ["command": "step"]]))
            frames.append(h.event("tool.complete", ["tool_id": .string("call-3-\(k)"), "name": "terminal", "result": ["stdout": "ok", "exit_code": 0]]))
        }
        frames.append(h.event("message.delta", ["text": "Then the second part."]))
        await h.emit(frames)
        // Stored: the prompt and the three tool rounds, no assistant text (the stand-in persists no partial).
        var stored = RowBackend.toolTurn(prompt: "Do three things", tools: 3, reply: "", firstRow: 3)
        stored.removeLast()
        backend.append(stored)
        s.stop()
        await h.emit([h.event("message.complete", ["text": "", "status": "interrupted"])])
        #expect(await waitUntil(timeout: .seconds(5)) { s.lastTurnEndReadAt != nil && s.refreshTask == nil })
        s.flushChanges()
        let reply = try #require(s.messages.last { $0.role == .assistant })
        #expect(reply.plainText.contains("Working on the first part now."))
        #expect(reply.plainText.contains("Then the second part."))
        #expect(reply.interrupted)
        #expect(s.messages.filter { $0.role == .user && $0.plainText == "Do three things" }.count == 1)
    }

    /// Minor: a long turn reloaded from history was split at the page boundaries, with stray "used 1 tool" entries.
    @Test func aLongTurnReloadedFromHistoryIsOneReply() async throws {
        let backend = RowBackend()
        backend.set(RowBackend.chat(1) + RowBackend.toolTurn(prompt: "Run seventy steps", tools: 70, reply: "All done.", firstRow: 3))
        let h = try harness(backend)
        let s = h.make()
        #expect(await h.open())
        #expect(await waitUntil { s.olderTask == nil && !s.isLoadingOlder })
        while s.hasOlder {
            s.loadOlder()
            #expect(await waitUntil { s.olderTask == nil && !s.isLoadingOlder })
        }
        s.flushChanges()
        #expect(s.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        let reply = try #require(s.messages.last)
        #expect(tools(reply).count == 70)
        #expect(!tools(reply).contains { $0.name == "tool" })            // no result without its call
        #expect(reply.plainText == "All done.")
    }
}
