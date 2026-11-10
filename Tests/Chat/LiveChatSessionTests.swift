import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

/// Drives a LiveChatSession against FakeGatewayClient with payloads captured from the stand-in gateways.
@MainActor
final class ChatHarness {
    let client: FakeGatewayClient
    let cache: TranscriptCache
    let stored: String
    let profile = "default"
    var session: LiveChatSession!
    var changes: [ChatChange] = []
    var drafts: [(String, String)] = []
    var notices: [String] = []

    /// REST answers by `limit` (or `limit@offset`); swap at runtime.
    nonisolated final class PageStore: Sendable { let map = Mutex<[String: Data]>([:]) }
    let pages = PageStore()

    init(stored: String = "20260929_120000_aabbcc01", resume: String = "perf-resume.json", ready: JSONValue? = nil) throws {
        self.stored = stored
        client = ready.map { FakeGatewayClient(ready: $0) } ?? FakeGatewayClient()
        cache = makeTempCache()
        let resumeResult = try ChatFixtures.json(resume)["result"] ?? .null
        let pages = self.pages
        client.onRest { path, query in
            let limit = query.first { $0.name == "limit" }?.value ?? "500"
            let offset = query.first { $0.name == "offset" }?.value ?? "0"
            return try pages.map.withLock { p in
                if let d = p["\(limit)@\(offset)"] ?? p[limit] { return d }
                throw HTTPError(status: 404, body: "no fixture page for \(path) limit=\(limit) offset=\(offset)")
            }
        }
        client.onCall { method, _ in
            switch method {
            case "session.resume", "session.activate": return resumeResult
            case "session.interrupt": return ["status": "interrupted"]
            case "session.active_list": return ["sessions": []]
            case "session.events.since": return ["events": [], "latest_seq": 0, "truncated": false, "epoch": "fixture-epoch"]
            default: return [:]
            }
        }
    }

    func setPage(_ key: String, _ fixture: String) throws {
        let data = try ChatFixtures.data(fixture)
        pages.map.withLock { $0[key] = data }
    }

    func setPage(_ key: String, rows: [JSONValue], hasMore: Bool = false) {
        let body: JSONValue = ["session_id": .string(stored), "profile": "default", "messages": .array(rows),
                               "pagination": ["limit": .number(Double(Int(key) ?? 24)), "offset": 0, "order": "latest",
                                              "returned": .number(Double(rows.count)), "has_more": .bool(hasMore)]]
        pages.map.withLock { $0[key] = encodeJSON(body) }
    }

    @discardableResult
    func make(lastActive: Date? = nil) -> LiveChatSession {
        let s = LiveChatSession(client: client, account: client.account, profile: profile, storedSessionId: stored, title: "Hermes",
                                head: nil, cache: cache, resolveSessionId: nil, lastActive: lastActive, frameMode: .manual)
        s.onChange = { [weak self] change in self?.changes.append(change) }
        s.onDraftReturned = { [weak self] text, reason in self?.drafts.append((text, reason)) }
        s.onNotice = { [weak self] text in self?.notices.append(text) }
        s.turnEndReadDelay = .milliseconds(20)
        s.busyRetryWindow = .milliseconds(400)
        s.busyRetryInterval = .milliseconds(20)
        s.ownerRetryInterval = .milliseconds(20)
        s.ownerWaitWindow = .seconds(5)
        s.ownerWaitShortWindow = .milliseconds(200)
        s.staleHold = .milliseconds(100)
        session = s
        return s
    }

    func open() async -> Bool {
        session.start()
        let ok = await waitUntil { self.session.openSettled }
        session.flushChanges()
        return ok
    }

    /// Emits captured frames in order, letting the session consume each one.
    func emit(_ frames: [JSONValue]) async {
        for frame in frames {
            client.emit(frame: frame)
            await Task.yield()
        }
        try? await Task.sleep(for: .milliseconds(30))
        session.flushChanges()
    }

    func event(_ type: String, _ payload: JSONValue = .null, seq: Int? = nil, sid: String? = nil) -> JSONValue {
        var params: [String: JSONValue] = ["type": .string(type), "session_id": .string(sid ?? session.runtimeSessionId ?? "")]
        if !payload.isNull { params["payload"] = payload }
        if let seq { params["seq"] = .number(Double(seq)) }
        return ["jsonrpc": "2.0", "method": "event", "params": .object(params)]
    }

    var assistant: ChatMessage? { session.messages.last { $0.role == .assistant } }
    var lastUser: ChatMessage? { session.messages.last { $0.role == .user } }
}

private func texts(_ m: ChatMessage?) -> [String] {
    (m?.parts ?? []).compactMap { if case .text(let t) = $0 { return t } else { return nil } }
}

private func toolCalls(_ m: ChatMessage?) -> [ToolCall] {
    (m?.parts ?? []).compactMap { if case .tool(let c) = $0 { return c } else { return nil } }
}

@Suite("Live chat session (spec 03 §4, 04)", .serialized)
@MainActor
struct LiveChatSessionTests {
    // MARK: Open

    @Test func cachedPaintIsSynchronousThenFreshPageKeepsIdentity() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        try h.setPage("97@23", "perf-page-older.json")
        let rows = try ChatFixtures.json("perf-page-latest-24.json")["messages"]?.array ?? []
        let folded = Hydration.fold(rows)
        h.cache.save(folded.messages, meta: folded.meta, account: h.client.account.id, profile: "default", storedId: h.stored)
        h.cache.flush()

        let s = h.make()
        #expect(s.messages.map(\.id) == folded.messages.map(\.id))      // first frame of the push already has the chat
        #expect(await h.open())
        #expect(!h.changes.contains { if case .reset = $0 { return true }; return false })
        // The one canonical resume param set (03 §3.1.1).
        let resume = try #require(h.client.calls("session.resume").first)
        #expect(resume.params == ["session_id": .string(h.stored), "cols": 96, "source": "desktop", "defer_history": true,
                                  "omit_messages": true, "profile": "default"])
        #expect(s.runtimeSessionId == "5cc537d1")
        let first = try #require(h.client.restLog.first)
        #expect(first.path == "/api/sessions/\(h.stored)/messages")
        #expect(first.query.map(\.name) == ["profile", "limit", "order", "include_compacted"])
        #expect(first.query.map(\.value) == ["default", "24", "latest", "true"])
        // Background older page completes the first 120 rows (03 §5.2) and prepends.
        #expect(await waitUntil { s.messages.count == 24 + 96 })
        s.flushChanges()
        #expect(h.changes.contains { if case .prependedOlder(96) = $0 { return true }; return false })
        #expect(s.messages.first?.id == "stored-row-725-user")         // older page rows 725…1105, joined on 1109
        #expect(s.hasOlder)
        #expect(s.statusText == nil)
    }

    @Test func staleCacheIsHeldUntilFreshRows() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let old = ChatMessage(id: "stored-row-5-user", role: .user, parts: [.text("old")], timestamp: nil, rowId: 5)
        h.cache.save([old], meta: [:], account: h.client.account.id, profile: "default", storedId: h.stored,
                     savedAt: Date(timeIntervalSinceNow: -60))
        h.cache.flush()
        let s = h.make(lastActive: Date())
        #expect(s.messages.isEmpty)                         // stale: held (03 §4.3)
        #expect(await h.open())
        #expect(s.messages.count == 24)
        #expect(!s.messages.contains { $0.id == "stored-row-5-user" })
    }

    // MARK: A scripted streaming turn (captured from the performance fixture)

    @Test func scriptedTurnFoldsAndKeepsIdentityThroughTheEndRead() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        try h.setPage("97@23", "perf-page-older.json")
        let s = h.make()
        s.turnEndReadDelay = .milliseconds(400)
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }

        let frames = try ChatFixtures.frames("perf-turn-frames.json")
        let ack = try #require(frames.first { $0["id"] != nil })["result"]!
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ack
            case "session.resume": return try ChatFixtures.json("perf-resume.json")["result"]!
            default: return [:]
            }
        }
        s.send("Run three steps")
        s.flushChanges()
        #expect(s.isRunning)
        #expect(s.statusText == "Thinking…")
        #expect(h.lastUser?.isPending == true)
        #expect(await waitUntil { h.lastUser?.isPending == false })
        let submit = try #require(h.client.calls("prompt.submit").first)
        // [authority] Each send names its own request id (sent only to a gateway-hosted session authority).
        var sent = try #require(submit.params.object)
        #expect(sent.removeValue(forKey: "submission_id")?.string?.hasPrefix("hq-local-user-") == true)
        #expect(JSONValue.object(sent) == ["session_id": "5cc537d1", "text": "Run three steps", "profile": "default"])
        #expect(h.lastUser?.rowId == 1202)

        let events = frames.filter { $0["method"]?.string == "event" }
        await h.emit(Array(events.prefix(4)))       // start, delta, tool.start, tool.complete
        #expect(s.isRunning)
        await h.emit(Array(events.dropFirst(4)))

        let reply = try #require(h.assistant)
        #expect(texts(reply) == ["Let me ", "run ", "three ", "steps. All done."])
        #expect(toolCalls(reply).map(\.state) == [.done, .done, .done])
        #expect(toolCalls(reply).map(\.title) == ["Ran 1 command", "Ran 1 command", "Ran 1 command"])
        #expect(reply.rowId == 1209)
        #expect(!reply.isStreaming)
        #expect(!s.isRunning)
        #expect(s.statusText == nil)
        #expect(s.toolDetail(messageId: reply.id, toolId: "performance-tool-0")?.command == "printf synthetic-step-0")

        // Turn-end read (+1.2 s, shortened): the stored rows replace the live content under the same ids.
        let idsBefore = s.messages.map(\.id)
        let revisionBefore = reply.revision
        try h.setPage("1", "perf-page-after-turn.json")
        try h.setPage("24", "perf-page-after-turn.json")
        h.changes = []
        #expect(await waitUntil { (s.messages.last.map(texts) ?? []) == ["Let me run three steps. All done."] })
        s.flushChanges()
        #expect(s.messages.map(\.id) == idsBefore)
        #expect(!h.changes.contains { if case .reset = $0 { return true }; return false })
        #expect(h.changes.contains { if case .updated(let ids) = $0 { return ids.contains(reply.id) }; return false })
        #expect(s.messages.last!.revision > revisionBefore)
        // The cache holds canonical stored ids for the next open.
        h.cache.flush()
        let cached = TranscriptCache(root: h.cache.root).load(account: h.client.account.id, profile: "default", storedId: h.stored)
        #expect(cached?.last?.id == "stored-row-1209-assistant")
        #expect(cached?.suffix(2).first?.id == "stored-row-1202-user")
    }

    @Test func deltasCoalesceToOneUpdatePerFrame() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming", "user_row_id": 3000] : [:] }
        s.send("hi")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "a"])])
        let id = try #require(h.assistant?.id)
        h.changes = []
        let rev = h.assistant!.revision
        for i in 0..<40 { h.client.emit(frame: h.event("message.delta", ["text": .string("\(i) ")])) }
        _ = await waitUntil { s.pendingDeltas.count == 1 && s.pendingDeltas[0].text.hasSuffix("39 ") }
        s.flushChanges()
        #expect(h.changes.count == 1)
        if case .updated(let ids)? = h.changes.first { #expect(ids == [id]) } else { Issue.record("expected one .updated") }
        #expect(h.assistant!.revision == rev + 1)
        #expect(texts(h.assistant).count == 1)
        #expect(texts(h.assistant).first?.hasSuffix("39 ") == true)
        #expect(s.statusText == "Writing…")
    }

    // MARK: Stop (04 §5, §5.6)

    @Test func stopMidStreamSealsAndIgnoresLateFrames() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ["status": "streaming", "user_row_id": 1210]
            case "session.interrupt": return ["status": "interrupted"]
            default: return [:]
            }
        }
        let events = try ChatFixtures.eventFrames("perf-stop-frames.json")
        let lastDelta = try #require(events.lastIndex { $0["params"]?["type"]?.string == "message.delta" })
        s.send("Write a long answer")
        await h.emit(Array(events[...lastDelta]))
        let shown = texts(h.assistant).joined()
        #expect(shown.hasPrefix("word0 "))
        s.stop()
        s.flushChanges()
        #expect(!s.isRunning)
        #expect(h.assistant?.interrupted == true)
        #expect(h.assistant?.isStreaming == false)
        #expect(await waitUntil { !h.client.calls("session.interrupt").isEmpty })
        #expect(h.client.calls("session.interrupt").first?.params == ["session_id": "5cc537d1", "profile": "default"])
        // Late deltas and the fixture's synthetic complete ("Stopped synthetic reply.") never replace what was shown.
        await h.emit([h.event("message.delta", ["text": "late "])] + Array(events[(lastDelta + 1)...]))
        #expect(texts(h.assistant).joined() == shown)
        #expect(!s.isRunning)
        #expect(!s.turn.stopTerminalPending)
        // A real Hermes interrupted partial that extends the bubble does land (extend-only).
        // Next send clears the stop.
        s.send("again")
        #expect(!s.turn.interrupted)
    }

    @Test func stopThatDidNotLandNeverDropsTheReply() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.interruptTimeout = .seconds(5)
        #expect(await h.open())
        let interrupts = Mutex(0)
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ["status": "streaming"]
            case "session.interrupt":
                let n = interrupts.withLock { $0 += 1; return $0 }
                if n == 1 { throw RPCError(code: 5032, message: "Hermes is still starting this session (loading tools)…", data: nil) }
                throw RPCError(code: 5032, message: "still starting", data: nil)
            default: return [:]
            }
        }
        s.send("hello")
        #expect(await waitUntil { h.lastUser?.isPending == false })   // the prompt went out; then Stop
        s.stop()
        #expect(await waitUntil { s.turn.stopPending })
        // The agent became ready: the turn starts; a second interrupt goes out; it fails too → stop hiding.
        await h.emit([h.event("message.start")])
        #expect(await waitUntil { interrupts.withLock { $0 } == 2 })
        #expect(await waitUntil { !s.turn.interrupted })
        await h.emit([h.event("message.complete", ["text": "Here is the whole reply.", "status": "complete"])])
        #expect(texts(h.assistant).joined() == "Here is the whole reply.")
        #expect(h.notices.contains("Couldn't stop — Hermes finished the reply."))
    }

    @Test func cancelledBeforeReadyIsAStopNotAnError() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming"] : ["status": "interrupted"] }
        s.send("hello")
        #expect(await waitUntil { h.lastUser?.isPending == false })
        s.stop()
        await h.emit([h.event("error", ["message": "Turn cancelled before the agent was ready"])])
        #expect(!s.messages.contains { $0.error != nil })
        #expect(h.notices.isEmpty)
        #expect(!s.turn.stopTerminalPending)
        #expect(s.messages.last?.interrupted == true)       // the "Stopped" row for the prompt
    }

    // MARK: Errors and non-streaming providers

    @Test func turnErrorsPaintAnErrorCard() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming"] : [:] }
        s.send("go")
        await h.emit([
            h.event("message.start"),
            h.event("message.delta", ["text": "I couldn't"]),
            h.event("message.complete", ["text": "I couldn't finish this: …", "status": "error", "error": "Codex usage limit",
                                         "recoverable": true, "error_surface": ["layer": "provider", "code": "rate_limit", "retryable": true]]),
        ])
        #expect(h.assistant?.error == "Codex usage limit")
        #expect(texts(h.assistant).isEmpty)
        #expect(!s.isRunning)

        s.send("again")
        await h.emit([h.event("message.start"), h.event("error", ["message": "provider exploded"])])
        #expect(s.messages.last?.error == "provider exploded")
        #expect(!s.isRunning)

        // No turn in flight: a chat-level problem card at the composer (transcript §6.2), nothing in the transcript.
        let count = s.messages.count
        await h.emit([h.event("error", ["message": "model not configured"])])
        #expect(s.messages.count == count)
        #expect(s.sessionProblem?.detail == "model not configured")
    }

    @Test func nonStreamingProviderReplyArrivesWhole() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming"] : [:] }
        s.send("tell me")
        await h.emit([
            h.event("message.start"),
            h.event("thinking.delta", ["text": "⏳ waiting on model…"]),
            h.event("reasoning.available", ["text": "Consider the colours."]),
            h.event("session.title", ["session_id": .string(h.stored), "title": "Colours"]),
        ])
        #expect(s.statusText == "Thinking…")
        await h.emit([
            h.event("message.complete", ["text": "Two colors: blue and yellow.", "status": "complete", "usage": [:]]),
            h.event("session.info", ["running": false, "title": "Colours"]),
        ])
        let reply = try #require(h.assistant)
        #expect(reply.parts == [.reasoning("Consider the colours."), .text("Two colors: blue and yellow.")])
        #expect(!s.isRunning)
    }

    // MARK: Send error codes (04 §2.4, §2.4.1)

    @Test func busyIsRetriedByCodeThenReturnedToTheComposer() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        let reject = try ChatFixtures.frames("perf-reject-4009-frames.json").first { $0["error"] != nil }!["error"]!
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw RPCError(code: reject["code"]!.int!, message: reject["message"]!.string!, data: nil) }
            return [:]
        }
        s.send("Are you there?")
        #expect(await waitUntil(timeout: .seconds(3)) { !h.drafts.isEmpty })
        #expect(h.client.calls("prompt.submit").count >= 3)
        #expect(h.drafts.first?.0 == "Are you there?")
        #expect(h.drafts.first?.1 == "session busy")
        #expect(!s.messages.contains { $0.role == .user && $0.plainText == "Are you there?" })
        #expect(s.sendFailure?.reason == "session busy", "the refusal is the Couldn’t Send card, not a transcript card")
        #expect(!s.isRunning)
    }

    @Test func busyOnceThenAccepted() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        let n = Mutex(0)
        h.client.onCall { method, _ in
            guard method == "prompt.submit" else { return [:] }
            if n.withLock({ $0 += 1; return $0 }) == 1 { throw RPCError(code: 4009, message: "subagent still running — wait for it to finish", data: nil) }
            return ["status": "streaming", "user_row_id": 77]
        }
        s.send("hi")
        #expect(await waitUntil { h.lastUser?.rowId == 77 })
        #expect(h.client.calls("prompt.submit").count == 2)
        #expect(h.drafts.isEmpty)
        #expect(s.isRunning)
    }

    /// The gateway's refusal while a cron job's or background delivery's one-shot `hermes chat` holds the bot's chat.
    nonisolated static func ownedRefusal(_ surface: String) -> RPCError {
        RPCError(code: 4090, message: "This chat is open in another Hermes window/terminal. Use it there, or start a new chat here.\n"
                 + "Details: session 20260101_090000_aa0001 opened by \(surface) 0m ago.", data: ["reason": "SESSION_NOT_OWNED"])
    }

    @Test func ownedByAOneShotRunWaitsThenSends() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.ownerRetryInterval = .milliseconds(20)
        s.silenceTimeout = .milliseconds(50)       // the wait must not trip the silence watchdog
        #expect(await h.open())
        let n = Mutex(0)
        h.client.onCall { method, _ in
            guard method == "prompt.submit" else { return method == "session.active_list" ? ["sessions": []] : [:] }
            if n.withLock({ $0 += 1; return $0 }) <= 10 { throw Self.ownedRefusal("cli") }
            return ["status": "streaming", "user_row_id": 91]
        }
        s.send("What the current line for sally and jack?")
        #expect(await waitUntil { s.computeStatus() == OwnerWait.backgroundTask.status })
        #expect(s.ownerWaitNotice == .backgroundTask)
        s.dismissOwnerWait()
        #expect(s.ownerWaitNotice == nil)                                   // ✕ hides the card…
        #expect(s.computeStatus() == OwnerWait.backgroundTask.status)       // …the wait and its status stay
        #expect(h.lastUser?.isPending == true)
        #expect(s.sendFailure == nil)
        #expect(await waitUntil(timeout: .seconds(3)) { h.lastUser?.rowId == 91 })
        #expect(h.client.calls("prompt.submit").count == 11)
        #expect(h.drafts.isEmpty)
        #expect(s.sendFailure == nil)
        #expect(s.isRunning)
        #expect(s.computeStatus() != OwnerWait.backgroundTask.status)
        #expect(s.ownerWaitNotice == nil)
        #expect(!s.messages.contains { $0.error == "Hermes ended this turn without a reply." })
    }

    /// Owner, 2026-10-23: the app went to the background while a send waited for a cron job; its next try found the link
    /// paused and the message came back to the field, though the job let go 16 s later. The wait outlives the pause.
    @Test func aSendWaitingForTheOwnerOutlivesAPausedLink() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.ownerRetryInterval = .milliseconds(20)
        #expect(await h.open())
        let n = Mutex(0)
        h.client.onCall { method, _ in
            guard method == "prompt.submit" else { return method == "session.active_list" ? ["sessions": []] : [:] }
            let attempt = n.withLock { $0 += 1; return $0 }
            if attempt <= 3 { throw Self.ownedRefusal("cli") }
            if attempt <= 8 { throw RPCError.notSent(.paused) }            // the app in the background
            if attempt <= 10 { throw RPCError.notSent(.offline) }
            if attempt <= 12 { throw Self.ownedRefusal("cli") }             // back, and the job still runs
            return ["status": "streaming", "user_row_id": 92]
        }
        s.send("Can you check the deploy?")
        #expect(await waitUntil { s.ownerWaitNotice == .backgroundTask })
        #expect(await waitUntil(timeout: .seconds(3)) { h.lastUser?.rowId == 92 })
        #expect(h.client.calls("prompt.submit").count == 13)
        #expect(h.drafts.isEmpty)
        #expect(s.sendFailure == nil)
        #expect(h.lastUser?.plainText == "Can you check the deploy?")
        #expect(h.lastUser?.error == nil)
        #expect(s.isRunning)
    }

    /// A sign-out while the send waits ends the wait: the words come back instead of a send nobody can see.
    @Test func aSignOutEndsTheOwnerWait() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.ownerRetryInterval = .milliseconds(20)
        #expect(await h.open())
        let n = Mutex(0)
        h.client.onCall { method, _ in
            guard method == "prompt.submit" else { return [:] }
            if n.withLock({ $0 += 1; return $0 }) <= 2 { throw Self.ownedRefusal("cli") }
            throw RPCError.notSent(.signedOut)
        }
        s.send("hi")
        #expect(await waitUntil(timeout: .seconds(3)) { !h.drafts.isEmpty })
        #expect(h.drafts.first?.0 == "hi")
        #expect(h.client.calls("prompt.submit").count == 3)
        #expect(s.ownerWaitNotice == nil)
        #expect(!s.isRunning)
    }

    /// A long time in the background can reap the chat's runtime more than once during one wait: each time it resumes
    /// and keeps waiting (the once-only resume counts from the last answer on a live runtime).
    @Test func aWaitingSendResumesEachTimeItsRuntimeIsReaped() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.ownerRetryInterval = .milliseconds(20)
        #expect(await h.open())
        let resume = try ChatFixtures.json("perf-resume.json")["result"]!
        let n = Mutex(0)
        h.client.onCall { method, _ in
            switch method {
            case "session.resume": return resume
            case "prompt.submit":
                switch n.withLock({ $0 += 1; return $0 }) {
                case 1, 3, 5: throw Self.ownedRefusal("cli")
                case 2, 4: throw RPCError(code: 4001, message: "session not found", data: nil)
                default: return ["status": "streaming", "user_row_id": 94]
                }
            default: return [:]
            }
        }
        s.send("hi")
        #expect(await waitUntil(timeout: .seconds(3)) { h.lastUser?.rowId == 94 })
        #expect(h.client.calls("session.resume").count == 3)          // open + one per reap
        #expect(h.drafts.isEmpty)
        #expect(s.sendFailure == nil)
    }

    @Test func ownedByAWindowIsRefusedAfterTheShortWait() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.ownerRetryInterval = .milliseconds(20)
        s.ownerWaitShortWindow = .milliseconds(200)
        #expect(await h.open())
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw Self.ownedRefusal("desktop") }
            return [:]
        }
        s.send("hi")
        #expect(await waitUntil { s.ownerWaitNotice == .otherWindow })
        #expect(await waitUntil(timeout: .seconds(3)) { !h.drafts.isEmpty })
        #expect(h.drafts.first?.0 == "hi")
        #expect(s.ownerWaitNotice == nil)
        #expect(s.sendFailure != nil)
        #expect(s.sendFailure?.copyText?.contains("opened by desktop") == true, "the holder stays copyable for a bug report")
        #expect(!s.isRunning)
        #expect(s.computeStatus() == nil)
    }

    /// A tester 2026-10-30: a Telegram or Discord turn holds the chat as "gateway:<platform>"; it ends on its own,
    /// so the send waits the long wait (not the short one for an earlier connection) and the card names the app.
    @Test func ownedByAMessagingTurnWaitsThenSends() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.ownerRetryInterval = .milliseconds(20)
        s.ownerWaitShortWindow = .milliseconds(50)     // ten refusals outlast it: the wait is the long one
        s.silenceTimeout = .milliseconds(50)
        #expect(await h.open())
        let n = Mutex(0)
        h.client.onCall { method, _ in
            guard method == "prompt.submit" else { return method == "session.active_list" ? ["sessions": []] : [:] }
            if n.withLock({ $0 += 1; return $0 }) <= 10 { throw Self.ownedRefusal("gateway:discord") }
            return ["status": "streaming", "user_row_id": 93]
        }
        s.send("hi")
        #expect(await waitUntil { s.ownerWaitNotice == .messagingTurn("Discord") })
        #expect(s.ownerWaitNotice?.cardBody.contains("a message from Discord") == true)
        #expect(s.computeStatus() == OwnerWait.messagingTurn("Discord").status)
        #expect(await waitUntil(timeout: .seconds(3)) { h.lastUser?.rowId == 93 })
        #expect(h.drafts.isEmpty)
        #expect(s.sendFailure == nil)
        #expect(s.ownerWaitNotice == nil)
    }

    /// Add-on 0.9.16: a chat open in the desktop app takes the app's message in the gateway's queue. `prompt.submit`
    /// answers `queued` + `forwarded` (no row id: the gateway writes the row), the gateway may finish the desktop's own
    /// reply first, then only `message.start` and `message.complete` are relayed (no deltas). The bubble is sent, the
    /// chat waits through the quiet stretch, and the reply shows once.
    @Test func aSendForwardedToTheGatewayWaitsQuietlyAndShowsItsReplyOnce() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.silenceTimeout = .milliseconds(150)
        #expect(await h.open())
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ["status": "queued", "admission_id": "adm-1", "forwarded": true]
            case "session.active_list": return ["sessions": []]
            default: return [:]
            }
        }
        s.send("from my phone")
        #expect(await waitUntil { h.lastUser?.isPending == false })
        try? await Task.sleep(for: .milliseconds(600))          // the desktop's own reply runs first: no frames here
        s.flushChanges()
        #expect(s.sendFailure == nil)
        #expect(!s.messages.contains { $0.error != nil })
        #expect(s.messages.filter { $0.role == .user && $0.plainText == "from my phone" }.count == 1)
        await h.emit([h.event("message.start")])
        await h.emit([h.event("message.complete", ["text": "THE ANSWER", "status": "complete"])])
        #expect(await waitUntil { s.messages.contains { $0.role == .assistant && $0.plainText.contains("THE ANSWER") } })
        #expect(s.messages.filter { $0.plainText.contains("THE ANSWER") }.count == 1)
        #expect(!s.messages.contains { $0.error != nil })
        #expect(await waitUntil { !s.isRunning })
    }

    @Test func theHolderNamesTheWait() {
        func wait(_ surface: String) -> OwnerWait { LiveChatSession.ownerWait(Self.ownedRefusal(surface)) }
        #expect(wait("gateway:telegram") == .messagingTurn("Telegram"))
        #expect(wait("gateway:bluebubbles") == .messagingTurn("iMessage"))
        #expect(wait("gateway") == .messagingTurn(nil))
        #expect(wait("gateway_boot") == .otherWindow)
        #expect(wait("cli") == .backgroundTask)
        #expect(wait("desktop") == .otherWindow)
        #expect(wait("tui") == .otherWindow)
        #expect(LiveChatSession.ownerWait(Self.ownerBusyRefusal()) == .runningReply)
        #expect(!OwnerWait.messagingTurn(nil).cardBody.contains("nil"))
    }

    @Test func stopWithdrawsASendWaitingForTheOwner() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.ownerRetryInterval = .milliseconds(20)
        #expect(await h.open())
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw Self.ownedRefusal("cli") }
            return [:]
        }
        s.send("hi")
        #expect(await waitUntil { s.ownerWaitNotice == .backgroundTask })
        s.cancelOwnerWait()
        #expect(await waitUntil(timeout: .seconds(3)) { !h.drafts.isEmpty })
        #expect(h.drafts.first?.0 == "hi")
        #expect(!s.messages.contains { $0.role == .user && $0.plainText == "hi" })
    }

    /// The gateway runs a turn in this chat and its queue couldn't take ours (build 337 feedback: "the gateway refused it").
    nonisolated static func ownerBusyRefusal(_ why: String = "the gateway refused it") -> RPCError {
        RPCError(code: 4090, message: "The gateway is running a turn in this chat and \(why). Nothing was sent. "
                 + "Send it again when the current turn ends.", data: ["reason": "SESSION_OWNER_BUSY"])
    }

    @Test func ownerBusyWaitsForTheRunningReplyThenSends() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.ownerRetryInterval = .milliseconds(20)
        s.ownerWaitShortWindow = .milliseconds(50)     // ten refusals outlast it: the wait is the long one
        s.silenceTimeout = .milliseconds(50)           // the wait must not trip the silence watchdog
        #expect(await h.open())
        let n = Mutex(0)
        h.client.onCall { method, _ in
            guard method == "prompt.submit" else { return method == "session.active_list" ? ["sessions": []] : [:] }
            if n.withLock({ $0 += 1; return $0 }) <= 10 { throw Self.ownerBusyRefusal() }
            return ["status": "streaming", "user_row_id": 92]
        }
        s.send("hi")
        #expect(await waitUntil { s.ownerWaitNotice == .runningReply })
        #expect(s.computeStatus() == OwnerWait.runningReply.status)
        #expect(h.lastUser?.isPending == true)
        #expect(s.sendFailure == nil)
        #expect(await waitUntil(timeout: .seconds(3)) { h.lastUser?.rowId == 92 })
        #expect(h.client.calls("prompt.submit").count == 11)
        #expect(h.drafts.isEmpty)
        #expect(s.sendFailure == nil)
        #expect(s.ownerWaitNotice == nil)
    }

    // [locked-chat] Owner 2026-11-05: a chat whose stored record names the bot's old folder is refused by the gateway
    // (`profile_mismatch`), and the queued work it holds can never run, so every send came back "busy" and waited.
    @Test func lockedChatRefusalsAreKnown() {
        #expect(LiveChatSession.isChatLocked(RPCError(code: 4001, message: "profile_mismatch", data: ["reason": "profile_mismatch"])))
        #expect(LiveChatSession.isChatLocked(Self.ownerBusyRefusal()))
        #expect(!LiveChatSession.isChatLocked(Self.ownerBusyRefusal("a rewind or attachment cannot join its queue")))
        #expect(!LiveChatSession.isChatLocked(RPCError(code: 4001, message: "runtime_draining", data: ["reason": "runtime_draining"])))
        #expect(!LiveChatSession.isChatLocked(Self.ownedRefusal("cli")))
    }

    @Test func lockedChatSendIsHandedBackWithNewChat() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw RPCError(code: 4001, message: "profile_mismatch", data: ["reason": "profile_mismatch"]) }
            return [:]
        }
        s.send("hi")
        #expect(await waitUntil(timeout: .seconds(3)) { !h.drafts.isEmpty })
        #expect(h.drafts.first?.0 == "hi")
        #expect(s.sessionProblem?.primary == .newChat)
        #expect(s.sessionProblem?.title == SessionProblem.chatLockedTitle)
        #expect(s.sendFailure == nil)
        #expect(h.client.calls("prompt.submit").count == 1)   // never resumed and resent: nothing can open it
    }

    @Test func busyWhoseHandOffKeepsBeingRefusedStopsWaiting() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.ownerRetryInterval = .milliseconds(20)
        s.lockedAfter = .milliseconds(200)
        #expect(await h.open())
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw Self.ownerBusyRefusal() }
            return method == "session.active_list" ? ["sessions": []] : [:]
        }
        s.send("hi")
        #expect(await waitUntil { s.ownerWaitNotice == .runningReply })   // a restart's drain refuses the same way: wait first
        #expect(await waitUntil(timeout: .seconds(3)) { s.sessionProblem?.primary == .newChat })
        #expect(h.drafts.first?.0 == "hi")
        #expect(s.ownerWaitNotice == nil)
        #expect(s.sendFailure == nil)
    }

    @Test func ownerBusyPastTheWaitIsRefusedInPlainWords() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.ownerRetryInterval = .milliseconds(20)
        s.ownerWaitWindow = .milliseconds(200)
        #expect(await h.open())
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw Self.ownerBusyRefusal() }
            return [:]
        }
        s.send("hi")
        #expect(await waitUntil { s.ownerWaitNotice == .runningReply })
        #expect(await waitUntil(timeout: .seconds(3)) { !h.drafts.isEmpty })
        #expect(h.drafts.first?.0 == "hi")
        #expect(s.ownerWaitNotice == nil)
        #expect(s.sendFailure?.body == "Your message is still in the box below. Hermes is still running a reply in this chat. "
                + "Send it again when that reply is done.")
        #expect(!s.isRunning)
    }

    /// The gateway's queue may hold it already: a second copy would run, so it is never resent and never handed back.
    @Test func ownerUnconfirmedIsMarkedAndNeverResent() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.ownerRetryInterval = .milliseconds(20)
        #expect(await h.open())
        h.client.onCall { method, _ in
            if method == "prompt.submit" {
                throw RPCError(code: 4090, message: "The gateway is running a turn in this chat and did not confirm your message in time. "
                               + "It may already be queued there: check the chat before sending it again.",
                               data: ["reason": "SESSION_OWNER_UNCONFIRMED"])
            }
            return [:]
        }
        s.send("hi")
        #expect(await waitUntil { h.lastUser?.error == LiveChatSession.unconfirmedMark })
        try await Task.sleep(for: .milliseconds(150))
        #expect(h.client.calls("prompt.submit").count == 1)
        #expect(h.drafts.isEmpty)
        #expect(s.sendFailure == nil)
        #expect(s.ownerWaitNotice == nil)
    }

    @Test(arguments: [(4001, "session not found"), (4007, "session no longer live; retry resume")])
    func staleRuntimeResumesOnceAndResubmits(code: Int, message: String) async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        let resume = try ChatFixtures.json("perf-resume.json")["result"]!
        let n = Mutex(0)
        h.client.onCall { method, _ in
            switch method {
            case "session.resume": return resume
            case "prompt.submit":
                if n.withLock({ $0 += 1; return $0 }) == 1 { throw RPCError(code: code, message: message, data: nil) }
                return ["status": "streaming", "user_row_id": 88]
            default: return [:]
            }
        }
        s.send("hi")
        #expect(await waitUntil { h.lastUser?.rowId == 88 })
        #expect(h.client.calls("session.resume").count == 2)          // open + one recovery
        #expect(h.client.calls("prompt.submit").count == 2)
        #expect(h.drafts.isEmpty)
    }

    @Test func explicitRefusalsAndUnconfirmedDelivery() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw RPCError(code: 4007, message: "session not found", data: nil) }
            return [:]
        }
        s.send("one")
        #expect(await waitUntil { h.drafts.count == 1 })
        #expect(h.client.calls("session.resume").count == 1)          // no recovery for this 4007 meaning

        h.client.onCall { method, _ in
            if method == "prompt.submit" {
                throw RPCError(code: 4090, message: "…already has a live owner…", data: ["reason": "SESSION_NOT_OWNED"])
            }
            return [:]
        }
        s.send("two")
        #expect(await waitUntil { h.drafts.count == 2 })

        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw URLError(.networkConnectionLost) }
            return [:]
        }
        let before = h.client.calls("prompt.submit").count
        s.send("three")
        #expect(await waitUntil { h.lastUser?.error == "Delivery unconfirmed" })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.client.calls("prompt.submit").count == before + 1)   // never auto-resent
        #expect(h.lastUser?.plainText == "three")
        #expect(h.lastUser?.isPending == false)
        #expect(h.drafts.count == 2)

        // "Check" (read-only): the gateway did store it.
        let rows = (try ChatFixtures.json("perf-page-latest-24.json")["messages"]?.array ?? [])
            + [["role": "user", "content": "three", "row_id": 5000, "timestamp": 1791585100]]
        h.setPage("24", rows: rows)
        let delivered = await s.checkDelivery(h.lastUser!.id)
        #expect(delivered == true)
        #expect(await waitUntil { h.lastUser?.error == nil })
        #expect(h.client.calls("prompt.submit").count == before + 1)
    }

    // MARK: Reconnect catch-up (04 §7)

    @Test func reconnectReplaysFromTheLastSeqWithoutDuplicates() async throws {
        let ready: JSONValue = ["heartbeat": true, "change_events": true, "replay_epoch": "plaid-epoch"]
        let h = try ChatHarness(stored: "20260101_090000_aa0001aa", resume: "plaid-resume.json", ready: ready)
        try h.setPage("24", "plaid-page-latest-24.json")
        try h.setPage("97@23", "plaid-page-older.json")
        let frames = try ChatFixtures.eventFrames("plaid-turn-frames.json")
        let rid = "07a49c24"

        // Control: everything live.
        let control = try ChatHarness(stored: "20260101_090000_aa0001aa", resume: "plaid-resume.json", ready: ready)
        try control.setPage("24", "plaid-page-latest-24.json")
        let cs = control.make()
        #expect(await control.open())
        control.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ["status": "streaming"]
            case "session.resume": return try ChatFixtures.json("plaid-resume.json")["result"]!
            default: return [:]
            }
        }
        cs.send("Finish the Plaid setup.")
        await control.emit(frames)

        let s = h.make()
        #expect(await h.open())
        #expect(s.runtimeSessionId == rid)
        let resume = try ChatFixtures.json("plaid-resume.json")["result"]!
        let replayable = frames.compactMap { f -> JSONValue? in
            guard f["params"]?["session_id"]?.string == rid else { return nil }
            return f["params"]
        }
        let cut = replayable.count / 2
        let cursor = replayable[cut - 1]["seq"]!.int!
        h.client.onCall { method, params in
            switch method {
            case "prompt.submit": return ["status": "streaming"]
            case "session.activate", "session.resume": return resume
            case "session.events.since":
                let last = params["last_seen"]?.int ?? 0
                // Overlap three already-seen frames to prove seq dedupe.
                let events = replayable.filter { ($0["seq"]?.int ?? 0) > last - 3 }
                return ["events": .array(events), "latest_seq": .number(Double(replayable.last!["seq"]!.int!)), "truncated": false,
                        "count": .number(Double(events.count)), "epoch": "plaid-epoch", "open_requests": []]
            default: return [:]
            }
        }
        s.send("Finish the Plaid setup.")
        // Live until the drop (keep the session-less sessions.changed frames in the stream: they must be ignored).
        let dropAt = frames.firstIndex { $0["params"]?["seq"]?.int == cursor }!
        await h.emit(Array(frames[...dropAt]))
        #expect(s.lastSeq == cursor)
        h.client.setConnection(.reconnecting(attempt: 1))
        try? await Task.sleep(for: .milliseconds(20))
        s.flushChanges()
        #expect(s.statusText == "Reconnecting…")
        h.client.setConnection(.ready)
        h.client.setReady(ready)
        #expect(await waitUntil { !h.client.calls("session.events.since").isEmpty })
        #expect(await waitUntil { !s.isRunning })
        s.flushChanges()
        let since = try #require(h.client.calls("session.events.since").first)
        #expect(since.params == ["session_id": .string(rid), "last_seen": .number(Double(cursor)), "profile": "default"])
        #expect(h.client.calls("session.activate").first?.params == ["session_id": .string(rid), "cols": 96, "omit_messages": true, "profile": "default"])
        // Same transcript as the control that saw every frame live.
        #expect(h.assistant?.parts == control.assistant?.parts)
        #expect(texts(h.assistant).joined() == texts(control.assistant).joined())
        #expect(!texts(h.assistant).joined().isEmpty)
        #expect(toolCalls(h.assistant).count == toolCalls(control.assistant).count)
    }

    @Test func epochChangeFallsBackToRESTAndInflight() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ["status": "streaming"]
            case "session.activate":
                return ["session_id": "5cc537d1", "running": true, "status": "streaming",
                        "inflight": ["user": "go", "assistant": "Partial answer so far", "streaming": true]]
            default: return [:]
            }
        }
        s.send("go")
        await h.emit([h.event("message.start", seq: 1), h.event("message.delta", ["text": "Partial "], seq: 2)])
        let restBefore = h.client.restLog.count
        h.client.setReady(["heartbeat": true, "change_events": true, "replay_epoch": "restarted"])
        #expect(await waitUntil { h.client.restLog.count > restBefore })
        #expect(await waitUntil { texts(h.assistant).joined() == "Partial answer so far" })
        #expect(h.client.calls("session.events.since").isEmpty)
        #expect(s.isRunning)
        await h.emit([h.event("message.delta", ["text": " and more."], seq: 1)])
        #expect(texts(h.assistant).joined() == "Partial answer so far and more.")
        #expect(s.messages.filter { $0.role == .user && $0.plainText == "go" }.count == 1)
    }

    @Test func openingMidTurnGraftsTheInflightTurn() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        h.client.onCall { method, _ in
            switch method {
            case "session.resume":
                return ["session_id": "5cc537d1", "session_key": .string("20260929_120000_aabbcc01"), "running": true,
                        "status": "streaming", "turn_started_at": 1790852460,
                        "inflight": ["user": "Write 600 words about a lighthouse keeper", "assistant": "The lamp turned at dusk, as it",
                                     "streaming": true]]
            default: return [:]
            }
        }
        let s = h.make()
        #expect(await h.open())
        #expect(s.isRunning)
        #expect(h.lastUser?.plainText == "Write 600 words about a lighthouse keeper")
        #expect(h.assistant?.isStreaming == true)
        await h.emit([h.event("message.delta", ["text": " always had."])])
        #expect(texts(h.assistant).joined() == "The lamp turned at dusk, as it always had.")
        await h.emit([h.event("message.complete", ["text": "The lamp turned at dusk, as it always had.", "status": "complete"])])
        #expect(!s.isRunning)
        #expect(s.messages.filter { $0.role == .assistant && $0.isStreaming }.isEmpty)
    }

    @Test func silenceWatchdogEndsALostTurn() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        try h.setPage("1", "perf-page-probe-1.json")
        let s = h.make()
        s.silenceTimeout = .milliseconds(150)
        #expect(await h.open())
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ["status": "streaming"]
            case "session.active_list": return try ChatFixtures.json("perf-active-list.json")["result"]!
            default: return [:]
            }
        }
        s.send("anyone?")
        await h.emit([h.event("message.start")])
        #expect(await waitUntil(timeout: .seconds(3)) { !s.isRunning })
        #expect(await waitUntil { s.messages.last?.error == "Hermes ended this turn without a reply." })
        #expect(!h.client.calls("session.active_list").isEmpty)
    }

    @Test func sessionsChangedIsThrottled() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        try h.setPage("1", "perf-page-probe-1.json")
        let s = h.make()
        s.changedPassGap = .milliseconds(300)
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        let before = h.client.restLog.count
        for _ in 0..<5 { h.client.emit(GatewayEvent(type: "sessions.changed", sessionId: "", seq: nil, payload: [:])) }
        try? await Task.sleep(for: .milliseconds(100))
        let afterBurst = h.client.restLog.count
        #expect(afterBurst - before == 1)            // leading edge: one probe read (limit=1), unchanged → stop
        #expect(h.client.restLog.last?.query.first { $0.name == "limit" }?.value == "1")
        for _ in 0..<5 { h.client.emit(GatewayEvent(type: "sessions.changed", sessionId: "", seq: nil, payload: [:])) }
        try? await Task.sleep(for: .milliseconds(450))
        #expect(h.client.restLog.count - afterBurst == 1)   // one trailing pass for the whole burst
    }

    private func holderRows(_ reply: String) throws -> [JSONValue] {
        let base = Array((try ChatFixtures.json("perf-page-latest-24.json")["messages"]?.array ?? []).suffix(22))
        return base + [["role": "user", "content": "from the job", "row_id": 9000, "timestamp": 1791590000],
                       ["role": "assistant", "content": .string(reply), "row_id": 9001, "timestamp": 1791590010]]
    }

    /// [owner-wait] While our send waits for a one-shot run, that run's saved reply is announced only by
    /// `sessions.changed`: the pass reads it, above our waiting bubble, and the read cuts nothing.
    @Test func ownerWaitChangedPassShowsHoldersReply() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.changedPassGap = .milliseconds(50)
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw Self.ownedRefusal("cli") }
            return method == "session.active_list" ? ["sessions": []] : [:]
        }
        s.send("mine")
        #expect(await waitUntil { s.ownerWaitNotice == .backgroundTask })
        let rows = try holderRows("The job's reply.")
        h.setPage("24", rows: rows, hasMore: true)
        h.setPage("1", rows: [rows.last!], hasMore: true)
        h.client.emit(GatewayEvent(type: "sessions.changed", sessionId: "", seq: nil, payload: [:]))
        #expect(await waitUntil(timeout: .seconds(2)) { s.messages.contains { $0.plainText == "The job's reply." } })
        s.flushChanges()
        let reply = try #require(s.messages.lastIndex { $0.plainText == "The job's reply." })
        let mine = try #require(s.messages.lastIndex { $0.role == .user && $0.plainText == "mine" })
        #expect(reply < mine)
        #expect(s.messages[mine].isPending)
        #expect(s.ownerWaitNotice == .backgroundTask)
        s.cancelOwnerWait()
    }

    /// [owner-wait] A wait refused after the short window reads the tail: what the other window saved meanwhile shows.
    @Test func refusedWindowWaitReadsTail() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.ownerRetryInterval = .milliseconds(20)
        s.ownerWaitShortWindow = .milliseconds(200)
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw Self.ownedRefusal("desktop") }
            return [:]
        }
        s.send("hi")
        #expect(await waitUntil { s.ownerWaitNotice == .otherWindow })
        let rows = try holderRows("Saved in the other window.")
        h.setPage("24", rows: rows, hasMore: true)
        h.setPage("1", rows: [rows.last!], hasMore: true)
        #expect(await waitUntil(timeout: .seconds(3)) { !h.drafts.isEmpty })
        #expect(await waitUntil(timeout: .seconds(3)) { s.messages.contains { $0.plainText == "Saved in the other window." } })
    }

    /// A turn live on the gateway still reads nothing on `sessions.changed` (its turn-end read is the one).
    @Test func aLiveTurnStillIgnoresSessionsChanged() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        try h.setPage("1", "perf-page-probe-1.json")
        let s = h.make()
        s.changedPassGap = .milliseconds(20)
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming", "user_row_id": 9100] : [:] }
        s.send("go")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Working"])])
        #expect(s.isRunning)
        let before = h.client.restLog.count
        h.client.emit(GatewayEvent(type: "sessions.changed", sessionId: "", seq: nil, payload: [:]))
        try? await Task.sleep(for: .milliseconds(200))
        #expect(h.client.restLog.count == before)
    }
}
