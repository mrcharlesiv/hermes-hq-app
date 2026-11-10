// [external-turn] "Herald messaged Hermes and I can't see that anything is happening" (owner, 2026-10-27): a turn the
// messaging gateway runs in an open chat shows Working…, its steps land as they're written, and Working… ends with it
// (docs/spec/03-chat-history.md §4.8).

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

@Suite("External turn: another process's turn shows as Working", .serialized)
@MainActor
struct ExternalTurnTests {
    // MARK: Pure rules

    private func message(_ role: ChatMessage.Role, _ parts: [ChatPart], id: String) -> ChatMessage {
        ChatMessage(id: id, role: role, parts: parts, timestamp: nil, rowId: nil)
    }

    private func tool(_ name: String) -> ChatPart {
        .tool(ToolCall(id: "c-\(name)", name: name, title: name, argsText: nil, summary: nil, state: .done, durationSeconds: nil))
    }

    @Test func historyRules() {
        let now = Date()
        let fresh = now.timeIntervalSince1970 - 30
        let old = now.timeIntervalSince1970 - 3600
        let prompt = message(.user, [.text("Hermes, a brief from Herald")], id: "stored-row-1-user")
        let steps = message(.assistant, [tool("skill_view"), tool("search_files")], id: "stored-row-2-tools")
        let reply = message(.assistant, [tool("search_files"), .text("Done: here it is.")], id: "stored-row-3-assistant")
        let silent = message(.system, [.text(Hydration.silentRunText)], id: "stored-row-4-system")
        let mine = message(.user, [.text("mine")], id: "local-9")

        // Steps with nothing after them, written recently: still running.
        #expect(ExternalTurn.historyUnfinished([prompt, steps], newestStoredAt: fresh, now: now))
        // Our own waiting bubble (not stored) doesn't hide it.
        #expect(ExternalTurn.historyUnfinished([prompt, steps, mine], newestStoredAt: fresh, now: now))
        // A prompt nobody answered yet, seconds ago: the gateway is on it.
        #expect(ExternalTurn.historyUnfinished([prompt], newestStoredAt: fresh, now: now))
        // A finished reply, a [SILENT] end, or stale rows: nothing runs.
        #expect(!ExternalTurn.historyUnfinished([prompt, reply], newestStoredAt: fresh, now: now))
        #expect(!ExternalTurn.historyUnfinished([prompt, steps, silent], newestStoredAt: fresh, now: now))
        #expect(!ExternalTurn.historyUnfinished([prompt, steps], newestStoredAt: old, now: now))
        #expect(!ExternalTurn.historyUnfinished([prompt], newestStoredAt: now.timeIntervalSince1970 - 300, now: now))
        #expect(!ExternalTurn.historyUnfinished([prompt, steps], newestStoredAt: nil, now: now))
        var failed = steps
        failed.error = "provider error"
        #expect(!ExternalTurn.historyUnfinished([prompt, failed], newestStoredAt: fresh, now: now))
    }

    @Test func ledgerRows() {
        let json: JSONValue = ["sessions": [["profile": "default", "id": "a", "status": "started", "kind": "admission"],
                                            ["profile": "herald", "id": "b", "status": "queued", "kind": "admission"]]]
        #expect(ExternalTurn.ledgerNames(json, ids: ["a"], profile: "default"))
        #expect(ExternalTurn.ledgerNames(json, ids: ["x", "a"], profile: ""))
        #expect(!ExternalTurn.ledgerNames(json, ids: ["b"], profile: "default"))
        #expect(ExternalTurn.ledgerNames(json, ids: ["b"], profile: "herald"))
        #expect(!ExternalTurn.ledgerNames(["sessions": []], ids: ["a"], profile: "default"))
    }

    // MARK: The open chat

    private func base() throws -> [JSONValue] {
        Array((try ChatFixtures.json("perf-page-latest-24.json")["messages"]?.array ?? []).suffix(18))
    }

    /// The delivery prompt and the steps the gateway wrote so far (the 17:30 shape: tool calls, no words yet).
    private func deliveryRows(at t: Double) -> [JSONValue] {
        [["role": "user", "content": "[From herald] Please review the brief.", "row_id": 9100, "timestamp": .number(t),
          "display_kind": "internal_notification"],
         ["role": "assistant", "content": "", "row_id": 9101, "timestamp": .number(t + 13),
          "tool_calls": [["id": "call-1", "type": "function",
                          "function": ["name": "search_files", "arguments": "{\"pattern\": \"brief\"}"]]]],
         ["role": "tool", "content": "{\"matches\": []}", "row_id": 9102, "timestamp": .number(t + 14), "tool_call_id": "call-1"],
         ["role": "assistant", "content": "", "row_id": 9103, "timestamp": .number(t + 16),
          "tool_calls": [["id": "call-2", "type": "function",
                          "function": ["name": "terminal", "arguments": "{\"command\": \"ls\"}"]]]]]
    }

    private func finished(at t: Double) -> [JSONValue] {
        deliveryRows(at: t) + [
            ["role": "tool", "content": "{\"stdout\": \"brief.md\", \"exit_code\": 0}", "row_id": 9104, "timestamp": .number(t + 40),
             "tool_call_id": "call-2"],
            ["role": "assistant", "content": "Reviewed Herald's brief.", "row_id": 9105, "timestamp": .number(t + 45)]]
    }

    private func setTail(_ h: ChatHarness, _ rows: [JSONValue]) {
        h.setPage("24", rows: Array(rows.suffix(24)), hasMore: true)
        h.setPage("1", rows: [rows.last!], hasMore: true)
    }

    /// No add-on route (404): the stored rows decide. The chat opens on a turn the gateway is running: Working…, the
    /// steps drawn, and the reply when it lands, with Working… gone.
    @Test func storedRowsShowTheGatewaysTurnUntilItsReply() async throws {
        ExternalTurn.ledgerMissingSince = [:]
        let saved = ExternalTurn.pollInterval
        ExternalTurn.pollInterval = .milliseconds(40)
        defer { ExternalTurn.pollInterval = saved }
        let h = try ChatHarness()
        let t = Date().timeIntervalSince1970 - 20
        setTail(h, try base() + deliveryRows(at: t))
        let s = h.make()
        var reported: [Bool] = []
        s.onExternalWorkChange = { reported.append($0) }
        #expect(await h.open())
        #expect(await waitUntil { s.externalWorking })
        s.flushChanges()
        #expect(s.statusText == "Working…")
        #expect(!s.isRunning)                                   // the composer keeps Send: a send joins the gateway's queue
        #expect(s.messages.last?.parts.contains { if case .tool = $0 { return true } else { return false } } == true)
        #expect(reported == [true])
        setTail(h, try base() + finished(at: t))
        #expect(await waitUntil(timeout: .seconds(3)) { !s.externalWorking })
        #expect(await waitUntil { s.messages.contains { $0.plainText.contains("Reviewed Herald's brief.") } })
        s.flushChanges()
        #expect(s.statusText == nil)
        #expect(reported == [true, false])
        #expect(h.client.restLog.contains { $0.path == ExternalTurn.ledgerPath })
    }

    /// The add-on's ledger is the word when present: Working… while it names the chat, even over rows that look done;
    /// and leaving the chat ends it.
    @Test func ledgerDecidesWhenTheAddOnHasIt() async throws {
        ExternalTurn.ledgerMissingSince = [:]
        let saved = ExternalTurn.pollInterval
        ExternalTurn.pollInterval = .milliseconds(40)
        defer { ExternalTurn.pollInterval = saved }
        let h = try ChatHarness()
        let old = Date().timeIntervalSince1970 - 7200        // rows alone would say "done long ago"
        let rows = try base() + deliveryRows(at: old)
        let pages = h.pages
        let working = Mutex(true)
        let stored = h.stored
        h.client.onRest { path, query in
            if path == ExternalTurn.ledgerPath {
                let on = working.withLock { $0 }
                let body: JSONValue = ["sessions": on ? [["profile": "default", "id": .string(stored), "status": "started",
                                                           "kind": "admission"]] : []]
                return encodeJSON(body)
            }
            let limit = query.first { $0.name == "limit" }?.value ?? "500"
            return try pages.map.withLock { p in
                if let d = p[limit] { return d }
                throw HTTPError(status: 404, body: "no page")
            }
        }
        setTail(h, rows)
        let s = h.make()
        #expect(await h.open())
        #expect(await waitUntil { s.externalWork == .ledger })
        s.flushChanges()
        #expect(s.statusText == "Working…")
        working.withLock { $0 = false }
        #expect(await waitUntil(timeout: .seconds(3)) { !s.externalWorking })
        working.withLock { $0 = true }
        h.client.emit(GatewayEvent(type: "sessions.changed", sessionId: "", seq: nil, payload: [:]))
        setTail(h, rows + [["role": "tool", "content": "{}", "row_id": 9104, "timestamp": .number(old + 1), "tool_call_id": "call-2"]])
        s.changedPassGap = .milliseconds(10)
        h.client.emit(GatewayEvent(type: "sessions.changed", sessionId: "", seq: nil, payload: [:]))
        #expect(await waitUntil(timeout: .seconds(3)) { s.externalWorking })
        s.stopObserving()
        #expect(!s.externalWorking)
    }

    /// A send refused because the gateway runs a turn here (`SESSION_OWNER_BUSY`) waits, and the gateway's steps keep
    /// landing above it; the header keeps the wait's words, and the waiting capsule stays away (owner-wait rules).
    @Test func aWaitingSendWatchesTheGatewaysTurn() async throws {
        ExternalTurn.ledgerMissingSince = [:]
        let saved = ExternalTurn.pollInterval
        ExternalTurn.pollInterval = .milliseconds(40)
        defer { ExternalTurn.pollInterval = saved }
        let h = try ChatHarness()
        let t = Date().timeIntervalSince1970 - 20
        setTail(h, try base() + deliveryRows(at: t))
        let s = h.make()
        #expect(await h.open())
        #expect(await waitUntil { s.externalWorking })
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw LiveChatSessionTests.ownerBusyRefusal() }
            return method == "session.active_list" ? ["sessions": []] : [:]
        }
        s.send("mine")
        #expect(await waitUntil { s.ownerWaitNotice == .runningReply })
        s.flushChanges()
        #expect(s.statusText == OwnerWait.runningReply.status)
        #expect(s.externalWorking)                              // still watched while ours waits
        setTail(h, try base() + finished(at: t))
        #expect(await waitUntil(timeout: .seconds(3)) { s.messages.contains { $0.plainText.contains("Reviewed Herald's brief.") } })
        let reply = try #require(s.messages.lastIndex { $0.plainText.contains("Reviewed Herald's brief.") })
        let mine = try #require(s.messages.lastIndex { $0.role == .user && $0.plainText == "mine" })
        #expect(reply < mine)
        s.cancelOwnerWait()
    }
}
