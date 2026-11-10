// One regression test per review finding (blocker/major first), driven like the live-session suite: FakeGatewayClient
// with captured fixture payloads, scripted RPC answers and events.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

private func joinedText(_ m: ChatMessage?) -> String {
    (m?.parts ?? []).compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
}

private func toolCount(_ m: ChatMessage) -> Int {
    m.parts.filter { if case .tool = $0 { return true } else { return false } }.count
}

/// Error the Net module throws for a body over its cap (`GatewayFailure.responseTooLarge`, description = stable code).
private struct TooLarge: Error, CustomStringConvertible { var description: String { "response-too-large" } }

@Suite("Review regressions: live chat", .serialized)
@MainActor
struct ReviewRegressionTests {
    /// Messages after the user row "go".
    private func turnRows(_ s: LiveChatSession, prompt: String = "go") -> [ChatMessage] {
        guard let u = s.messages.lastIndex(where: { $0.role == .user && $0.plainText == prompt }) else { return [] }
        return Array(s.messages[(u + 1)...])
    }

    // MARK: Blocker — REST fallback in the middle of a tool turn

    @Test func restFallbackMidToolTurnShowsTheReplyOnce() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        let baseRows = try ChatFixtures.json("perf-page-latest-24.json")["messages"]?.array ?? []
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ["status": "streaming", "user_row_id": 5000]
            case "session.activate":
                return ["session_id": "5cc537d1", "running": true, "inflight": ["user": "go", "assistant": "Checking. ", "streaming": true]]
            case "session.events.since":
                return ["events": [], "latest_seq": 99, "truncated": true, "count": 0, "epoch": "fixture-epoch", "open_requests": []]
            default: return [:]
            }
        }
        s.send("go")
        await h.emit([h.event("message.start", seq: 1), h.event("message.delta", ["text": "Checking. "], seq: 2),
                      h.event("tool.start", ["tool_id": "c1", "name": "terminal", "args": ["command": "ls"]], seq: 3),
                      h.event("tool.complete", ["tool_id": "c1", "name": "terminal", "result": ["stdout": "a", "exit_code": 0]], seq: 4)])
        let live = try #require(h.assistant)
        // The gateway already persisted this turn's user row, tool-call row and tool row.
        let midRows: [JSONValue] = Array(baseRows.suffix(21)) + [
            ["role": "user", "content": "go", "row_id": 5000, "timestamp": 1791590000],
            ["role": "assistant", "content": "Checking. ", "row_id": 5001, "timestamp": 1791590001,
             "tool_calls": [["id": "c1", "type": "function", "function": ["name": "terminal", "arguments": "{\"command\":\"ls\"}"]]]],
            ["role": "tool", "content": "{\"stdout\":\"a\",\"exit_code\":0}", "tool_call_id": "c1", "row_id": 5002, "timestamp": 1791590002],
        ]
        h.setPage("24", rows: midRows, hasMore: true)
        h.client.setReady(["heartbeat": true, "change_events": true, "replay_epoch": "fixture-epoch"])   // replay truncated → REST
        #expect(await waitUntil { !h.client.calls("session.events.since").isEmpty })
        try? await Task.sleep(for: .milliseconds(150))
        s.flushChanges()
        let mid = turnRows(s)
        #expect(mid.map(\.id) == [live.id])                      // one bubble owns the turn; no stored partial beside it
        #expect(mid.first.map(toolCount) == 1)
        #expect(mid.first?.isStreaming == true)
        #expect(joinedText(mid.first) == "Checking. ")
        #expect(s.messages.filter { $0.role == .user && $0.plainText == "go" }.count == 1)

        let finalRows = midRows + [["role": "assistant", "content": "Done.", "row_id": 5003, "timestamp": 1791590003]]
        h.setPage("24", rows: Array(finalRows.suffix(24)), hasMore: true)
        h.setPage("1", rows: [finalRows.last!], hasMore: true)
        await h.emit([h.event("message.delta", ["text": "Done."], seq: 100),
                      h.event("message.complete", ["text": "Done.", "status": "complete"], seq: 101)])
        #expect(await waitUntil { s.lastTurnEndReadAt != nil && s.refreshTask == nil })
        try? await Task.sleep(for: .milliseconds(50))
        s.flushChanges()
        let after = turnRows(s)
        #expect(after.map(\.id) == [live.id])                    // the sealed bubble took the stored reply's place
        #expect(joinedText(after.first) == "Checking. Done.")
        #expect(after.first.map(toolCount) == 1)
        #expect(after.first?.isStreaming == false)
        // …and the cache holds it once, under the stored id.
        s.saveCache()
        h.cache.flush()
        let cached = try #require(TranscriptCache(root: h.cache.root).load(account: h.client.account.id, profile: "default", storedId: h.stored))
        #expect(cached.suffix(2).map(\.id) == ["stored-row-5000-user", "stored-row-5001-assistant"])
        #expect(!cached.contains { $0.isLocal })
    }

    @Test func aTurnFromAnotherDeviceNeverCutsAwayThePreviousReply() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        let base = Array((try ChatFixtures.json("perf-page-latest-24.json")["messages"]?.array ?? []).suffix(20))
        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming", "user_row_id": 5000] : [:] }
        s.send("first")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Reply one"]),
                      h.event("message.complete", ["text": "Reply one", "status": "complete"])])
        let afterFirst = base + [["role": "user", "content": "first", "row_id": 5000, "timestamp": 1791590000],
                                 ["role": "assistant", "content": "Reply one", "row_id": 5001, "timestamp": 1791590001]]
        h.setPage("24", rows: afterFirst, hasMore: true)
        await s.refreshTail(force: true)
        // Away; another device starts a turn. Back: no cursor, so REST + the inflight snapshot.
        let other: JSONValue = ["role": "user", "content": "other", "row_id": 5002, "timestamp": 1791590002]
        h.setPage("24", rows: afterFirst + [other, ["role": "assistant", "content": "Part", "row_id": 5003, "timestamp": 1791590003]],
                  hasMore: true)
        h.client.onCall { method, _ in
            method == "session.activate"
                ? ["session_id": "5cc537d1", "running": true, "inflight": ["user": "other", "assistant": "Part", "streaming": true]]
                : [:]
        }
        s.lastSeq = nil
        h.client.setReady(["heartbeat": true, "change_events": true, "replay_epoch": "fixture-epoch"])
        #expect(await waitUntil { s.isRunning && !s.parking })
        s.flushChanges()
        #expect(s.messages.suffix(4).map(\.plainText) == ["first", "Reply one", "other", "Part"])
        #expect(s.messages.last?.isStreaming == true)
        // A read while that turn runs keeps the previous reply and the single live bubble.
        h.setPage("24", rows: afterFirst + [other, ["role": "assistant", "content": "Part and", "row_id": 5003, "timestamp": 1791590003]],
                  hasMore: true)
        await s.refreshTail(force: true)
        s.flushChanges()
        #expect(s.messages.suffix(4).map(\.plainText) == ["first", "Reply one", "other", "Part"])
        let done: JSONValue = ["role": "assistant", "content": "Part and more", "row_id": 5003, "timestamp": 1791590003]
        h.setPage("24", rows: afterFirst + [other, done], hasMore: true)
        h.setPage("1", rows: [done], hasMore: true)
        await h.emit([h.event("message.delta", ["text": " and more"]),
                      h.event("message.complete", ["text": "Part and more", "status": "complete"])])
        #expect(s.messages.suffix(4).map(\.plainText) == ["first", "Reply one", "other", "Part and more"])
        #expect(await waitUntil { s.lastTurnEndReadAt != nil && s.refreshTask == nil })
        s.flushChanges()
        #expect(s.messages.suffix(4).map(\.plainText) == ["first", "Reply one", "other", "Part and more"])
        #expect(s.messages.filter { $0.plainText.hasPrefix("Part") }.count == 1)
    }

    @Test func graftLetsASealedLiveBubbleClaimAStoredCopyAlreadyShown() {
        let user = ChatMessage(id: "stored-row-10-user", role: .user, parts: [.text("go")], timestamp: nil, rowId: 10)
        let storedCopy = ChatMessage(id: "stored-row-11-assistant", role: .assistant, parts: [.text("Checking.")], timestamp: nil, rowId: 11)
        let live = ChatMessage(id: "local-assistant-2", role: .assistant, parts: [.text("Checking. Done.")], timestamp: nil, rowId: nil)
        let fresh = [user, ChatMessage(id: "stored-row-11-assistant", role: .assistant, parts: [.text("Checking. Done.")], timestamp: nil, rowId: 11)]
        let graft = TranscriptMerge.graft(fresh: fresh, freshMeta: [:], onto: [user, storedCopy, live], previousMeta: [:], aliases: [:],
                                          replaceAll: false)
        #expect(graft.messages.map(\.id) == ["stored-row-10-user", "local-assistant-2"])
        #expect(graft.aliases == ["stored-row-11-assistant": "local-assistant-2"])
    }

    /// A reply to a delivery (no prompt bubble of its own) matches its stored row by `final_assistant_row_id`, not the
    /// previous turn's reply.
    @Test func graftMatchesAnUnpromptedLiveReplyByRowId_previousReplyStored() {
        let u1 = ChatMessage(id: "stored-row-10-user", role: .user, parts: [.text("go")], timestamp: nil, rowId: 10)
        let a1 = ChatMessage(id: "stored-row-11-assistant", role: .assistant, parts: [.text("One.")], timestamp: nil, rowId: 11)
        let u2 = ChatMessage(id: "stored-row-12-user", role: .user, parts: [.text("delivered")], timestamp: nil, rowId: 12)
        let a2 = ChatMessage(id: "stored-row-13-assistant", role: .assistant, parts: [.text("Two.")], timestamp: nil, rowId: 13)
        let live = ChatMessage(id: "local-assistant-5", role: .assistant, parts: [.text("Two.")], timestamp: nil, rowId: 13)
        let graft = TranscriptMerge.graft(fresh: [u1, a1, u2, a2], freshMeta: [:], onto: [u1, a1, live], previousMeta: [:],
                                          aliases: [:], replaceAll: false)
        #expect(graft.messages.map(\.id) == ["stored-row-10-user", "stored-row-11-assistant", "stored-row-12-user", "local-assistant-5"])
        #expect(graft.aliases == ["stored-row-13-assistant": "local-assistant-5"])
    }

    @Test func graftNoDuplicateWhenPreviousReplyAliased() {
        let u1 = ChatMessage(id: "stored-row-10-user", role: .user, parts: [.text("go")], timestamp: nil, rowId: 10)
        let a1 = ChatMessage(id: "stored-row-11-assistant", role: .assistant, parts: [.text("One.")], timestamp: nil, rowId: 11)
        let u2 = ChatMessage(id: "stored-row-12-user", role: .user, parts: [.text("delivered")], timestamp: nil, rowId: 12)
        let a2 = ChatMessage(id: "stored-row-13-assistant", role: .assistant, parts: [.text("Two.")], timestamp: nil, rowId: 13)
        let shown = [ChatMessage(id: "local-user-1", role: .user, parts: [.text("go")], timestamp: nil, rowId: 10),
                     ChatMessage(id: "local-assistant-1", role: .assistant, parts: [.text("One.")], timestamp: nil, rowId: 11),
                     ChatMessage(id: "local-assistant-5", role: .assistant, parts: [.text("Two.")], timestamp: nil, rowId: 13)]
        let graft = TranscriptMerge.graft(fresh: [u1, a1, u2, a2], freshMeta: [:], onto: shown, previousMeta: [:],
                                          aliases: ["stored-row-10-user": "local-user-1", "stored-row-11-assistant": "local-assistant-1"],
                                          replaceAll: false)
        let ids = graft.messages.map(\.id)
        #expect(ids == ["local-user-1", "local-assistant-1", "stored-row-12-user", "local-assistant-5"])
        #expect(Set(ids).count == ids.count)
    }

    // MARK: Overlapping reconnects

    @Test func overlappingReconnectsLoseNoFrames() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        let rid = try #require(s.runtimeSessionId)
        let deltas = (2...12).map { (n: Int) -> JSONValue in h.event("message.delta", ["text": .string("d\(n) ")], seq: n) }
        let all: [JSONValue] = [h.event("message.start", seq: 1)] + deltas
        h.client.onCall { method, params in
            switch method {
            case "prompt.submit": return ["status": "streaming"]
            case "session.activate":
                try await Task.sleep(for: .milliseconds(150))
                return ["session_id": .string(rid), "running": true]
            case "session.events.since":
                let last = params["last_seen"]?.int ?? 0
                let evs = all.compactMap { $0["params"] }.filter { ($0["seq"]?.int ?? 0) > last }
                return ["events": .array(evs), "latest_seq": 12, "truncated": false, "count": .number(Double(evs.count)),
                        "epoch": "fixture-epoch", "open_requests": []]
            default: return [:]
            }
        }
        s.send("go")
        await h.emit(Array(all[0...4]))                      // seq 1…5 live, then the link drops (6…9 missed)
        let ready: JSONValue = ["heartbeat": true, "change_events": true, "replay_epoch": "fixture-epoch"]
        h.client.setReady(ready)
        try? await Task.sleep(for: .milliseconds(30))
        h.client.setReady(ready)                             // flappy link: a second gateway.ready
        try? await Task.sleep(for: .milliseconds(30))
        await h.emit([all[9]])                               // live seq 10 while the second reconnect is still re-binding
        #expect(await waitUntil { s.lastSeq == 12 && !s.parking })
        s.flushChanges()
        #expect(joinedText(h.assistant) == (2...12).map { "d\($0) " }.joined())
        #expect(h.client.calls("session.events.since").map { $0.params["last_seen"]?.int } == [5])
    }

    // MARK: Retry after a failed open

    @Test func retryAfterAFailedOpenOpensAgainWhileStillOnScreen() async throws {
        let h = try ChatHarness()
        h.client.onCall { method, _ in
            if method == "session.resume" { throw URLError(.timedOut) }
            return [:]
        }
        let s = h.make()
        s.start()
        #expect(await waitUntil { s.openFinished })
        #expect(s.openError == "Couldn't load this chat.")
        #expect(s.messages.isEmpty)
        try h.setPage("24", "perf-page-latest-24.json")
        try h.setPage("97@23", "perf-page-older.json")
        let resume = try ChatFixtures.json("perf-resume.json")["result"]!
        h.client.onCall { method, _ in method == "session.resume" ? resume : [:] }
        s.start()                                            // Retry: the error screen is still observing
        #expect(s.openError == nil)
        #expect(await waitUntil { s.openSettled })
        #expect(s.messages.count >= 24)
        #expect(s.runtimeSessionId == "5cc537d1")
        #expect(await waitUntil { s.messages.count == 24 + 96 })   // paging works: the older page joined
        #expect(s.hasOlder)
        #expect(s.oldestRowId == 725)
        s.start()                                            // not failed any more: a no-op
        #expect(h.client.calls("session.resume").count == 3)       // failed open (2 tries) + the retry
    }

    @Test func retryResolvesAnUnresolvedStoredIdAgain() async throws {
        let client = FakeGatewayClient()
        let cache = makeTempCache()
        let attempts = Mutex(0)
        let page = try ChatFixtures.data("perf-page-latest-24.json")
        client.onRest { _, _ in page }
        let resume = try ChatFixtures.json("perf-resume.json")["result"]!
        client.onCall { method, _ in method == "session.resume" ? resume : [:] }
        let s = LiveChatSession(client: client, account: client.account, profile: "default", storedSessionId: nil, title: "",
                                head: nil, cache: cache, resolveSessionId: {
                                    let n = attempts.withLock { $0 += 1; return $0 }
                                    if n == 1 { throw URLError(.timedOut) }
                                    return "20260929_120000_aabbcc01"
                                }, frameMode: .manual)
        s.start()
        #expect(await waitUntil { s.openFinished })
        #expect(s.openError != nil)
        s.stopObserving()
        s.start()                                            // leave and come back: Retry
        #expect(await waitUntil { s.openSettled })
        #expect(attempts.withLock { $0 } == 2)
        #expect(s.messages.count == 24)
        #expect(s.openError == nil)
    }

    @Test func aNewChatOpensOnTheIntroWithoutReadingHistory() async throws {
        let client = FakeGatewayClient()
        let rest = Mutex(0)
        client.onRest { _, _ in rest.withLock { $0 += 1 }; throw URLError(.fileDoesNotExist) }   // no row until the first prompt
        client.onCall { method, _ in
            if method == "session.resume" { throw RPCError(code: 4007, message: "session not found", data: nil) }
            return [:]
        }
        let s = LiveChatSession(client: client, account: client.account, profile: "default", storedSessionId: nil, title: "New Chat",
                                head: nil, cache: makeTempCache(), resolveSessionId: { "20261018_083300_aabbcc02" },
                                startsNew: true, frameMode: .manual)
        s.start()
        #expect(s.openPhase == .open)                        // the intro at once, not the skeleton
        #expect(await waitUntil { s.openFinished })
        #expect(s.openPhase == .open)
        #expect(s.openError == nil)
        #expect(!s.chatGone)
        #expect(rest.withLock { $0 } == 0)
    }

    /// [tiles] New Tile opens a new chat and sends at once (2026-11-03): the chat is made on the gateway once, and the
    /// send goes to the runtime the screen listens on. Twice made, the turn ran on one and the screen called it done.
    @Test func aNewChatOpenedAndSentAtOnceIsMadeOnce() async throws {
        let client = FakeGatewayClient()
        client.onRest { _, _ in throw URLError(.fileDoesNotExist) }
        let made = Mutex(0)
        let resume = try ChatFixtures.json("perf-resume.json")["result"]!
        let submits = Mutex(0)
        client.onCall { method, _ in
            if method == "session.resume" { return resume }
            if method == "prompt.submit" { submits.withLock { $0 += 1 }; return ["status": "streaming", "user_row_id": 4001] }
            return [:]
        }
        let s = LiveChatSession(client: client, account: client.account, profile: "default", storedSessionId: nil, title: "New Chat",
                                head: nil, cache: makeTempCache(), resolveSessionId: {
                                    let n = made.withLock { $0 += 1; return $0 }
                                    try await Task.sleep(for: .milliseconds(50))
                                    return "20261103_122000_aabbcc0\(n)"
                                }, startsNew: true, frameMode: .manual)
        s.start()
        s.send("Make me a live tile")
        #expect(await waitUntil { submits.withLock { $0 } == 1 })
        #expect(made.withLock { $0 } == 1)
        #expect(s.storedSessionId == "20261103_122000_aabbcc01")
    }

    /// A tile asked of a new chat (2026-11-03): the open and the send began together, each made its own session, and
    /// the chat bound the empty one's runtime while the turn ran in the other. The turn's end never reached it, and
    /// the bot said "Working…" after it was done. One session, one resume, and the end lands.
    @Test func aSendAsTheNewChatOpensMakesOneSessionAndHearsTheEnd() async throws {
        let client = FakeGatewayClient()
        client.onRest { _, _ in throw URLError(.fileDoesNotExist) }
        let made = Mutex(0)
        client.onCall { method, params in
            switch method {
            case "session.resume":
                let stored = params["session_id"]?.string ?? ""
                return ["session_id": .string("rt-" + stored), "stored_session_id": .string(stored), "running": false]
            case "prompt.submit": return ["status": "streaming", "user_row_id": 7001]
            default: return [:]
            }
        }
        let s = LiveChatSession(client: client, account: client.account, profile: "inbox", storedSessionId: nil, title: "New Chat",
                                head: nil, cache: makeTempCache(), resolveSessionId: {
                                    let n = made.withLock { $0 += 1; return $0 }
                                    try await Task.sleep(for: .milliseconds(50))
                                    return "20261103_122003_aabbc\(n)"
                                }, startsNew: true, frameMode: .manual)
        s.start()
        s.send("Make a tile")
        #expect(await waitUntil { client.calls("prompt.submit").count == 1 })
        #expect(made.withLock { $0 } == 1)
        #expect(client.calls("session.resume").count == 1)
        let runtime = try #require(client.calls("prompt.submit").first?.params["session_id"]?.string)
        #expect(s.runtimeSessionId == runtime)
        s.flushChanges()
        #expect(s.isRunning)
        client.emit(GatewayEvent(type: "message.start", sessionId: runtime, seq: 2, payload: [:]))
        client.emit(GatewayEvent(type: "message.complete", sessionId: runtime, seq: 3,
                                 payload: ["text": "Tile made", "status": "complete"]))
        client.emit(GatewayEvent(type: "session.info", sessionId: runtime, seq: 4, payload: ["running": false]))
        #expect(await waitUntil { s.flushChanges(); return !s.isRunning })
    }

    // MARK: Sending while a reply runs (04 §6.2 M1 queue)

    @Test func sendingWhileBusyQueuesAndDrainsAfterTheTurn() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        let n = Mutex(0)
        h.client.onCall { method, _ in
            guard method == "prompt.submit" else { return [:] }
            let k = n.withLock { $0 += 1; return $0 }
            return ["status": "streaming", "user_row_id": .number(Double(3000 + k))]
        }
        s.send("first")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Hello"])])
        s.redirectUnsupported = true   // a gateway that can’t add to a reply: typed words queue
        let live = try #require(h.assistant)
        s.send("second")
        s.flushChanges()
        #expect(s.queuedMessages.map(\.text) == ["second"])                     // a queue card, not a transcript row
        #expect(!s.messages.contains { $0.role == .user && $0.plainText == "second" })
        #expect(h.client.calls("prompt.submit").count == 1)
        await h.emit([h.event("message.delta", ["text": " world"]),
                      h.event("message.complete", ["text": "Hello world", "status": "complete",
                                                   "persisted_turn": ["user_row_id": 3001, "final_assistant_row_id": 3003]]),
                      h.event("session.info", ["running": false])])
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 2 })
        let drained = try #require(h.client.calls("prompt.submit").last)
        var sent = try #require(drained.params.object)
        #expect(sent.removeValue(forKey: "submission_id") != nil)   // [authority] its own request id
        #expect(JSONValue.object(sent) == ["session_id": "5cc537d1", "text": "second", "profile": "default", "queued": true])
        #expect(s.queuedMessages.isEmpty)
        #expect(await waitUntil { h.lastUser?.rowId == 3002 })
        let tail = Array(s.messages.suffix(3))
        #expect(tail.map(\.role) == [.user, .assistant, .user])
        #expect(tail[0].plainText == "first" && tail[0].rowId == 3001)
        #expect(tail[1].id == live.id)
        #expect(joinedText(tail[1]) == "Hello world")
        #expect(tail[2].plainText == "second")
        #expect(s.messages.filter(\.isStreaming).isEmpty)
        #expect(s.messages.filter { joinedText($0) == "Hello world" }.count == 1)
        #expect(s.isRunning)                                                   // the drained prompt's turn
    }

    @Test func queueDrainsWithoutRunningFalseAfterAShortWait() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.queueDrainFallback = .milliseconds(60)
        #expect(await h.open())
        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming"] : [:] }
        s.send("first")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Hi"])])
        s.send("second")
        await h.emit([h.event("message.complete", ["text": "Hi", "status": "complete"])])
        #expect(h.client.calls("prompt.submit").count == 1)
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 2 })
        #expect(h.client.calls("prompt.submit").last?.params["queued"] == true)
    }

    @Test func stopParksTheQueueAndSendNowResumesIt() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.queueDrainFallback = .milliseconds(30)
        #expect(await h.open())
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ["status": "streaming"]
            case "session.interrupt": return ["status": "interrupted"]
            default: return [:]
            }
        }
        s.send("first")
        s.redirectUnsupported = true   // a gateway that can’t add to a reply: typed words queue
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Long answer"])])
        s.send("second")
        s.send("third")
        s.stop()
        #expect(s.isQueueParked)
        await h.emit([h.event("message.complete", ["text": "Long answer", "status": "interrupted"]),
                      h.event("session.info", ["running": false])])
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.client.calls("prompt.submit").count == 1)                       // parked: nothing went out
        let third = try #require(s.queuedMessages.last)
        s.sendQueuedNow(third.id)                                               // the row's send arrow
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 2 })
        #expect(h.client.calls("prompt.submit").last?.params["text"] == "third")
        #expect(s.queuedMessages.map(\.text) == ["second"])
        #expect(s.removeQueued(s.queuedMessages[0].id) == "second")
        #expect(s.queuedMessages.isEmpty)
    }

    // MARK: Stop overtaking a send

    @Test func stopDuringThePreSendResumeNeverSends() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        s.runtimeSessionId = nil                                 // e.g. after session.reclaimed
        h.client.onCall { method, _ in
            switch method {
            case "session.resume":
                try await Task.sleep(for: .milliseconds(200))
                return try ChatFixtures.json("perf-resume.json")["result"]!
            case "prompt.submit": return ["status": "streaming", "user_row_id": 4000]
            case "session.interrupt": return ["status": "interrupted"]
            default: return [:]
            }
        }
        let count = s.messages.count
        s.send("do it")
        try? await Task.sleep(for: .milliseconds(20))
        s.stop()
        #expect(await waitUntil { !h.drafts.isEmpty })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.client.calls("prompt.submit").isEmpty)
        #expect(h.drafts.first?.0 == "do it")
        #expect(h.drafts.first?.1 == "Stopped before sending")
        #expect(s.messages.count == count)                       // no bubble, no Stopped marker
        #expect(!s.isRunning)
    }

    @Test func stopWhileThePromptIsInFlightInterruptsAgainAfterTheAck() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit":
                try await Task.sleep(for: .milliseconds(150))
                return ["status": "streaming", "user_row_id": 4100]
            case "session.interrupt": return ["status": "interrupted"]
            default: return [:]
            }
        }
        s.send("go")
        #expect(await waitUntil { !h.client.calls("prompt.submit").isEmpty })
        s.stop()
        #expect(await waitUntil { h.client.calls("session.interrupt").count == 2 })
        #expect(h.lastUser?.rowId == 4100)
        #expect(h.drafts.isEmpty)
    }

    // MARK: Local rows are never cached

    @Test func localCardsNeverComeBackFromTheCache() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        h.client.onCall { method, _ in
            if method == "prompt.submit" { throw RPCError(code: 4090, message: "already has a live owner", data: nil) }
            return [:]
        }
        s.send("x")
        #expect(await waitUntil { !h.drafts.isEmpty })
        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming", "user_row_id": 4000] : [:] }
        s.send("y")
        #expect(await waitUntil { h.lastUser?.rowId == 4000 })
        s.stop()
        s.stopObserving()
        h.cache.flush()
        let cached = try #require(TranscriptCache(root: h.cache.root).load(account: h.client.account.id, profile: "default",
                                                                          storedId: h.stored))
        #expect(!cached.contains { $0.isLocal })
        #expect(cached.last?.id == "stored-row-4000-user")      // an acknowledged prompt is backend truth
        h.client.onCall { method, _ in method == "session.resume" ? (try ChatFixtures.json("perf-resume.json")["result"]!) : [:] }
        let s2 = LiveChatSession(client: h.client, account: h.client.account, profile: "default", storedSessionId: h.stored,
                                 title: "", head: nil, cache: h.cache, resolveSessionId: nil, frameMode: .manual)
        #expect(!s2.messages.contains { $0.isLocal })
        s2.start()
        #expect(await waitUntil { s2.openSettled })
        #expect(s2.messages.filter(\.isLocal).isEmpty)
    }

    // MARK: Retry plumbing after reopen

    @Test func watchdogComesBackWithTheScreen() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        try h.setPage("1", "perf-page-probe-1.json")
        let s = h.make()
        #expect(await h.open())
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ["status": "streaming"]
            case "session.activate": return ["session_id": "5cc537d1", "running": true]
            case "session.active_list": return try ChatFixtures.json("perf-active-list.json")["result"]!
            default: return [:]
            }
        }
        s.send("anyone?")
        await h.emit([h.event("message.start")])
        s.stopObserving()
        #expect(s.watchdogTask == nil)
        s.silenceTimeout = .milliseconds(150)
        s.start()                                                // back on screen while the turn still runs
        #expect(s.watchdogTask != nil)
        #expect(await waitUntil(timeout: .seconds(3)) { !s.isRunning })   // the lost turn end is still caught
        #expect(await waitUntil { s.messages.last?.error == "Hermes ended this turn without a reply." })
    }

    @Test func aSnapshotSayingNotRunningFreesTheNextSend() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        h.client.onCall { method, _ in
            switch method {
            case "prompt.submit": return ["status": "streaming"]
            case "session.interrupt": throw URLError(.networkConnectionLost)   // the socket dropped with the Stop
            case "session.activate": return ["session_id": "5cc537d1", "running": false]
            default: return [:]
            }
        }
        s.send("go")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Partial"])])
        s.stop()
        #expect(s.turn.stopTerminalPending)
        h.client.setReady(["heartbeat": true, "change_events": true, "replay_epoch": "fixture-epoch"])
        #expect(await waitUntil { !s.turn.stopTerminalPending })
        let start = ContinuousClock.now
        s.send("next")
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 2 })
        #expect(ContinuousClock.now - start < .seconds(2))       // no 6 s stop hold
        #expect(h.client.calls("prompt.submit").last?.params["queued"] == nil)
    }

    @Test func aStopHoldThatTimesOutDoesNotHoldTheNextSendAgain() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.stopHoldWindow = .milliseconds(100)
        #expect(await h.open())
        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming"] : ["status": "interrupted"] }
        s.send("one")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "x"])])
        s.stop()
        s.send("two")
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 2 })
        #expect(h.client.calls("prompt.submit").last?.params["queued"] == true)   // held 100 ms, then queued behind
        #expect(!s.turn.stopTerminalPending)
    }

    // MARK: Leaving the screen

    @Test func frameTickerStaysDeadAfterInvalidateUntilRevived() {
        var fired = 0
        let ticker = FrameTicker(mode: .manual) { fired += 1 }
        ticker.schedule()
        ticker.fire()
        #expect(fired == 1)
        ticker.invalidate()
        ticker.schedule()
        #expect(!ticker.isScheduled)
        ticker.revive()
        ticker.schedule()
        #expect(ticker.isScheduled)
    }

    @Test func changesMadeWhileAwayArriveAsOneResetOnReturn() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        try h.setPage("97@23", "perf-page-older.json")
        let s = h.make()
        #expect(await h.open())
        #expect(await waitUntil { s.messages.count == 120 })
        s.retainedMessagesOffScreen = 30
        s.stopObserving()
        #expect(s.messages.count == 30)                          // old rows released (03 §5.4)
        #expect(s.hasOlder)
        #expect(!s.ticker.isScheduled)
        h.changes = []
        s.start()
        s.flushChanges()
        #expect(h.changes.contains { if case .reset = $0 { return true }; return false })
        // The offset was rewound by the released rows, so paging reads them again from the new oldest row.
        #expect(s.nextOffset == 30)
        #expect(s.oldestRowId == s.messages.first?.rowId)
    }

    // MARK: Refresh

    @Test func refreshKeepsThe24RowPageWhenThe120RowReadFails() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        let rows: [JSONValue] = (0..<24).map { (i: Int) -> JSONValue in
            let role: JSONValue = i % 2 == 0 ? "user" : "assistant"
            let row: [String: JSONValue] = ["role": role, "content": .string("new \(i)"), "row_id": .number(Double(9000 + i)),
                                            "timestamp": .number(Double(1791600000 + i))]
            return .object(row)
        }
        h.setPage("24", rows: rows, hasMore: true)               // shares no row with what is held → would read 120
        await s.refreshTail(force: true)                         // …and the 120-row read fails (no fixture page)
        #expect(h.client.restLog.last?.query.first { $0.name == "limit" }?.value == "120")
        #expect(s.messages.last?.id == "stored-row-9023-assistant")
    }

    @Test func aForcedRefreshStaysForcedWhenCoalesced() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        try h.setPage("1", "perf-page-probe-1.json")
        let s = h.make()
        #expect(await h.open())
        _ = await waitUntil { s.olderTask == nil }
        let before = h.client.restLog.count
        s.startRefresh(force: false)
        s.startRefresh(force: true)                              // coalesced into the pass after this one
        #expect(await waitUntil { s.refreshTask == nil })
        let limits = h.client.restLog.dropFirst(before).map { $0.query.first { $0.name == "limit" }?.value }
        #expect(limits == ["1", "24"])                           // a probe, then a real (forced) read
    }

    // MARK: Errors routed to the roster, failed hydration

    @Test func profileGoneOnResumeOrInterruptRefetchesTheRoster() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        h.client.onCall { method, _ in
            if method == "session.resume" { throw RPCError(code: 4064, message: "Profile 'gone' does not exist.", data: nil) }
            return [:]
        }
        let s = h.make()
        var stale = 0
        s.onRosterStale = { stale += 1 }
        #expect(await h.open())
        #expect(stale == 1)
        let resume = try ChatFixtures.json("perf-resume.json")["result"]!
        h.client.onCall { method, _ in
            switch method {
            case "session.resume": return resume
            case "prompt.submit": return ["status": "streaming"]
            case "session.interrupt": throw RPCError(code: 4064, message: "Profile 'gone' does not exist.", data: nil)
            default: return [:]
            }
        }
        s.send("hi")
        #expect(await waitUntil { h.lastUser?.isPending == false })
        s.stop()
        #expect(await waitUntil { stale == 2 })
        #expect(!s.turn.stopTerminalPending)
    }

    @Test func failedResumeHydrationRetiresTheRuntime() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        let rid = try #require(s.runtimeSessionId)
        await h.emit([h.event("session.resume_progress", ["phase": "history", "status": "failed", "message": "history hydration timed out"],
                              seq: 3),
                      h.event("error", ["message": "history hydration timed out"], sid: rid)])
        #expect(s.runtimeSessionId == nil)
        #expect(s.lastSeq == nil)
        #expect(s.sessionProblem?.detail == "history hydration timed out")
        h.client.onCall { method, _ in
            switch method {
            case "session.resume": return try ChatFixtures.json("perf-resume.json")["result"]!
            case "prompt.submit": return ["status": "streaming"]
            default: return [:]
            }
        }
        s.send("again")
        #expect(await waitUntil { !h.client.calls("prompt.submit").isEmpty })
        #expect(h.client.calls("session.resume").count == 2)     // re-resumed before the send
    }

    @Test func framesEmittedBeforeTheResumeAnswerAreKept() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let client = h.client
        client.onCall { method, _ in
            guard method == "session.resume" else { return [:] }
            // The gateway re-binds, snapshots, and the turn emits a delta before the answer is written.
            client.emit(GatewayEvent(type: "message.delta", sessionId: "5cc537d1", seq: 41, payload: ["text": " always had."]))
            try await Task.sleep(for: .milliseconds(60))
            return ["session_id": "5cc537d1", "session_key": "20260929_120000_aabbcc01", "running": true, "status": "streaming",
                    "inflight": ["user": "Write about a lighthouse keeper", "assistant": "The lamp turned at dusk, as it", "streaming": true]]
        }
        let s = h.make()
        #expect(await h.open())
        s.flushChanges()
        #expect(joinedText(h.assistant) == "The lamp turned at dusk, as it always had.")
        #expect(s.lastSeq == 41)
    }

    // MARK: Compressed lineage

    @Test func aPageAlreadyAtTheLineageTipNeedsNoSecondRead() async throws {
        let h = try ChatHarness(stored: "old-root")
        let rows = try ChatFixtures.json("perf-page-latest-24.json")["messages"]?.array ?? []
        let body: JSONValue = ["session_id": "tip-id", "profile": "default", "messages": .array(rows),
                               "pagination": ["limit": 24, "offset": 0, "order": "latest", "returned": 24, "has_more": false]]
        h.pages.map.withLock { $0["24"] = encodeJSON(body) }
        h.client.onCall { method, _ in
            method == "session.resume" ? ["session_id": "5cc537d1", "session_key": "tip-id", "running": false] : [:]
        }
        let s = h.make()
        #expect(await h.open())
        #expect(h.client.restLog.count == 1)                     // no redundant re-read of the same tip
        #expect(s.storedSessionId == "old-root")                 // still keyed by the id it was opened with
        h.cache.flush()
        let disk = TranscriptCache(root: h.cache.root)
        #expect(disk.load(account: h.client.account.id, profile: "default", storedId: "old-root")?.count == 24)
        #expect(disk.load(account: h.client.account.id, profile: "default", storedId: "tip-id")?.count == 24)
    }

    // MARK: Interrupted partial (extend-only merge)

    @Test func anInterruptedPartialThatExtendsWhatWasShownLands() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming"] : ["status": "interrupted"] }
        s.send("go")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "The keeper climbed"])])
        let bubble = try #require(h.assistant)
        s.stop()
        await h.emit([h.event("message.complete", ["text": "The keeper climbed the stairs", "status": "interrupted"])])
        #expect(h.assistant?.id == bubble.id)
        #expect(joinedText(h.assistant) == "The keeper climbed the stairs")
        #expect(h.assistant?.interrupted == true)
        // A partial that doesn't extend it (rewritten) never replaces what was shown.
        s.send("again")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Second"])])
        s.stop()
        await h.emit([h.event("message.complete", ["text": "Different text", "status": "interrupted"])])
        #expect(joinedText(h.assistant) == "Second")
    }

    @Test func aLateInterruptedPartialLandsInItsOwnTurnAfterANewSend() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.stopHoldWindow = .seconds(3)
        #expect(await h.open())
        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming"] : ["status": "interrupted"] }
        s.send("first")
        await h.emit([h.event("message.start")])
        s.stop()                                                  // before any token: a Stopped marker
        s.send("second")                                          // held behind the stopped turn
        await h.emit([h.event("message.complete", ["text": "Partial of first", "status": "interrupted"])])
        let rows = s.messages.suffix(3)
        #expect(rows.map(\.plainText) == ["first", "Partial of first", "second"])
        #expect(Array(rows)[1].interrupted)
    }
}

@Suite("Review regressions: data")
struct ReviewDataRegressionTests {
    @Test func toolHeavyChatCachesItsWholeFirstScreen() throws {
        let cache = makeTempCache()
        var rows: [JSONValue] = []
        var id = 1
        let body = String(repeating: "let value = compute(); // a typical source line\n", count: 130)
        for t in 0..<20 {
            rows.append(["role": "user", "content": .string("Look at file \(t)"), "id": .number(Double(id)), "timestamp": 1]); id += 1
            var calls: [JSONValue] = []
            for k in 0..<3 {
                calls.append(["id": .string("c\(t)-\(k)"), "type": "function",
                              "function": ["name": "read_file", "arguments": .string("{\"path\": \"/repo/src/f\(k).swift\"}")]])
            }
            rows.append(["role": "assistant", "content": "", "id": .number(Double(id)), "timestamp": 2, "tool_calls": .array(calls)]); id += 1
            for k in 0..<3 {
                rows.append(["role": "tool", "tool_call_id": .string("c\(t)-\(k)"), "tool_name": "read_file",
                             "content": .string(ChatJSON.stringify(["content": .string(body)])), "id": .number(Double(id)), "timestamp": 3]); id += 1
            }
            rows.append(["role": "assistant", "content": "Here is what I found.", "id": .number(Double(id)), "timestamp": 4]); id += 1
        }
        let folded = Hydration.fold(rows, pageSeq: 1)
        #expect(folded.messages.count == 40)
        cache.save(folded.messages, meta: folded.meta, account: "a", profile: "p", storedId: "tools")
        cache.flush()
        let entry = try #require(TranscriptCache(root: cache.root).loadEntry(account: "a", profile: "p", storedId: "tools"))
        #expect(entry.messages.count == 40)                        // the whole first screen, not 8
        #expect(cache.diskBytes <= 256 * 1024)
        let details = entry.meta.values.flatMap(\.tools.values)
        #expect(details.count == 60)
        #expect(details.allSatisfy { $0.isCacheCopy && ($0.stdout?.utf8.count ?? 0) <= ToolDetail.cacheHeadBytes })
    }

    @Test func toolDetailsWithoutRoomStillKeep40Messages() throws {
        // A cap the slim details don't fit under: the "40 without tool details" rung comes before 40 → 8.
        let cache = makeTempCache(limits: TranscriptCache.Limits(entryBytes: 32 * 1024))
        var messages: [ChatMessage] = []
        var meta: [String: MessageMeta] = [:]
        for i in 0..<40 {
            let call = ToolCall(id: "t\(i)", name: "terminal", title: "Ran 1 command", argsText: String(repeating: "a", count: 3000),
                                summary: "ok", state: .done, durationSeconds: nil)
            let id = "stored-row-\(i + 1)-assistant"
            messages.append(ChatMessage(id: id, role: .assistant, parts: [.text("m\(i)"), .tool(call)], timestamp: nil, rowId: i + 1))
            var mm = MessageMeta()
            var d = ToolDetail(); d.stdout = String(repeating: "o", count: 900)
            mm.tools["t\(i)"] = d
            meta[id] = mm
        }
        let data = try #require(cache.admit(TranscriptEntry(messages: messages, meta: meta, savedAt: Date())))
        let entry = try TranscriptEntry.decode(data)
        #expect(entry.messages.count == 40)
        #expect(entry.meta.isEmpty)
        if case .tool(let call)? = entry.messages.last?.parts.last { #expect(call.argsText?.utf8.count == 512) }
        else { Issue.record("tool part lost") }
    }

    @Test func diffOfALongTranscriptIsLinear() {
        var changes = ChangeSet()
        let old = (0..<4000).map { (i: Int) in
            ChatMessage(id: "stored-row-\(i)-user", role: .user, parts: [.text("m\(i)")], timestamp: nil, rowId: i)
        }
        let new = Array(old.dropFirst())
        let start = ContinuousClock.now
        let out = TranscriptMerge.diff(old: old, new: new, into: &changes)
        let elapsed = ContinuousClock.now - start
        #expect(out.count == 3999)
        #expect(changes.emissions().count == 1)
        #expect(elapsed < .milliseconds(150))
    }

    @Test func pluginRouteStaysOffAfterAFallbackUntilTheGatewayRestarts() async throws {
        let ready: JSONValue = ["replay_epoch": "e1", "performance": ["version": 1, "history_display": 1,
                                                                     "history_path": "hermes-hq-performance.v1"]]
        let features = try #require(PerformanceFeatures(ready: ready))
        let client = FakeGatewayClient(ready: ready)
        let core = try ChatFixtures.data("perf-page-latest-24.json")
        client.onRest { path, _ in
            if path.hasPrefix("/api/plugins/") { throw HTTPError(status: 404, body: "Not Found") }
            return core
        }
        let gate = PluginRouteGate()
        let request = HistoryRequest(storedSessionId: "s1", profile: "default", limit: 24)
        _ = try await HistoryAPI.fetch(client: client, request: request, features: features, gate: gate)
        #expect(client.restLog.count == 2)
        let (_, usedPlugin) = try await HistoryAPI.fetch(client: client, request: request, features: features, gate: gate)
        #expect(!usedPlugin)
        #expect(client.restLog.count == 3)
        #expect(client.restLog.last?.path == "/api/sessions/s1/messages")      // straight to the core route
        client.setReady(["replay_epoch": "e2"])                                 // gateway restarted: try the plugin again
        _ = try await HistoryAPI.fetch(client: client, request: request, features: features, gate: gate)
        #expect(client.restLog.suffix(2).map(\.path) == ["/api/plugins/hermes-hq-performance/sessions/s1/messages",
                                                          "/api/sessions/s1/messages"])
    }

    @Test func responseTooLargeHalvesTheLimitThenDropsInlineImages() async throws {
        let client = FakeGatewayClient()
        let page = try ChatFixtures.data("perf-page-latest-24.json")
        client.onRest { _, query in
            let limit = Int(query.first { $0.name == "limit" }?.value ?? "") ?? 500
            if limit > 3 { throw TooLarge() }
            return page
        }
        _ = try await HistoryAPI.fetch(client: client, request: HistoryRequest(storedSessionId: "s", profile: "default", limit: 24),
                                       features: nil, gate: PluginRouteGate())
        #expect(client.restLog.map { $0.query.first { $0.name == "limit" }?.value } == ["24", "12", "6", "3"])

        let images = FakeGatewayClient()
        images.onRest { _, query in
            if query.first(where: { $0.name == "inline_images" })?.value != "false" { throw TooLarge() }
            return page
        }
        let (got, _) = try await HistoryAPI.fetch(client: images, request: HistoryRequest(storedSessionId: "s", profile: "default", limit: 24),
                                                  features: nil, gate: PluginRouteGate())
        #expect(got.requestedLimit == 1)
        #expect(images.restLog.map { $0.query.first { $0.name == "limit" }?.value } == ["24", "12", "6", "3", "1", "1"])
        #expect(images.restLog.last?.query.contains(URLQueryItem(name: "inline_images", value: "false")) == true)
        #expect(!HistoryAPI.isResponseTooLarge(HTTPError(status: 500, body: nil)))
    }

    @Test func aCorruptCacheFileIsDroppedNotTrappedOn() throws {
        let cache = makeTempCache()
        let m = [ChatMessage(id: "stored-row-1-user", role: .user, parts: [.text("hi")], timestamp: nil, rowId: 1)]
        cache.save(m, meta: [:], account: "a", profile: "p", storedId: "bad")
        cache.flush()
        let file = try #require(FileManager.default.enumerator(at: cache.root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.first { $0.pathExtension == "hqt" })
        // Magic, savedAt, flags, then a message count of UInt64.max (10-byte varint).
        var bytes = Array("HQT1".utf8) + [UInt8](repeating: 0, count: 8) + [0]
        bytes += [UInt8](repeating: 0xFF, count: 9) + [0x01]
        try Data(bytes).write(to: file)
        let fresh = TranscriptCache(root: cache.root)
        #expect(fresh.loadEntry(account: "a", profile: "p", storedId: "bad") == nil)
        fresh.flush()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // A truncated string length past the end, too.
        var short = BinaryWriter()
        for b in TranscriptEntry.magic { short.byte(b) }
        short.double(0); short.byte(0); short.varint(1); short.varint(UInt64(Int.max))
        #expect(throws: (any Error).self) { try TranscriptEntry.decode(short.data) }
    }

    @Test func clipCutsByBytesOnScalarBoundaries() {
        #expect(ChatText.clip("hello", max: 10) == "hello")
        #expect(ChatText.clip("日本語", max: 4) == "日")
        #expect(ChatText.clip("ab", max: 0) == "")
        let big = String(repeating: "x", count: 1_000_000)
        #expect(ChatText.clip(big, max: 8192).utf8.count == 8192)
    }
}
