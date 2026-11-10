// Typing while a reply runs adds to it, as on the desktop (owner 2026-10-28): plain text goes into the running reply
// through `session.redirect` instead of waiting in the queue; what the gateway turns down joins the queue.

import Foundation
import Testing
@testable import HermesHQNative

private func texts(_ m: ChatMessage) -> String {
    m.parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
}

@MainActor @Suite("Composer · typing while a reply runs adds to it", .serialized)
struct TypedSteerTests {
    /// A chat whose reply to "first" is streaming "Working on it"; `redirect` answers `session.redirect`.
    private func busy(redirect: @escaping @Sendable (JSONValue) async throws -> JSONValue) async throws -> (ChatHarness, LiveChatSession) {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.queueDrainFallback = .milliseconds(30)
        #expect(await h.open())
        h.client.onCall { method, params in
            switch method {
            case "prompt.submit": return ["status": "streaming"]
            case "session.interrupt": return ["status": "interrupted"]
            case "session.redirect": return try await redirect(params)
            default: return [:]
            }
        }
        s.send("first")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Working on it"])])
        return (h, s)
    }

    /// The transcript after the page, as "role: text".
    private func tail(_ s: LiveChatSession, _ n: Int) -> [String] {
        s.messages.suffix(n).map { "\($0.role == .user ? "user" : "bot"): \(texts($0))" }
    }

    @Test func plainTextGoesIntoTheRunningReply() async throws {
        let (h, s) = try await busy { p in ["status": "redirected", "text": p["text"] ?? ""] }
        s.send("also check the README")
        // The bubble shows at once, under what the bot already said; nothing waits in the queue.
        #expect(s.messages.last?.role == .user)
        #expect(s.messages.last.map(texts) == "also check the README")
        #expect(s.queuedMessages.isEmpty)
        #expect(await waitUntil { h.client.calls("session.redirect").count == 1 })
        let call = try #require(h.client.calls("session.redirect").first)
        #expect(call.params["text"] == "also check the README")
        #expect(call.params["profile"] == "default")
        #expect(await waitUntil { s.messages.last?.isPending == false })
        // What the bot says next lands below the correction, in a bubble of its own.
        await h.emit([h.event("message.delta", ["text": "Checked the README too."])])
        #expect(tail(s, 4) == ["user: first", "bot: Working on it", "user: also check the README", "bot: Checked the README too."])
        await h.emit([h.event("message.complete", ["text": "Checked the README too.", "status": "complete"]),
                      h.event("session.info", ["running": false])])
        #expect(tail(s, 4) == ["user: first", "bot: Working on it", "user: also check the README", "bot: Checked the README too."])
        #expect(!s.isRunning)
        #expect(h.client.calls("prompt.submit").count == 1, "the correction never went out as a turn of its own")
        #expect(s.messages.allSatisfy { !$0.isStreaming })
    }

    @Test func aFinalTextWithNoDeltasStillLandsBelowTheCorrection() async throws {
        let (h, s) = try await busy { p in ["status": "redirected", "text": p["text"] ?? ""] }
        s.send("shorter please")
        #expect(await waitUntil { s.messages.last?.isPending == false })
        await h.emit([h.event("message.complete", ["text": "Short version.", "status": "complete"]),
                      h.event("session.info", ["running": false])])
        #expect(tail(s, 4) == ["user: first", "bot: Working on it", "user: shorter please", "bot: Short version."])
    }

    @Test func turnedDownItJoinsTheQueueAndTheReplyGoesOnWhereItWas() async throws {
        let (h, s) = try await busy { p in ["status": "rejected", "text": p["text"] ?? ""] }
        s.send("next thing")
        #expect(await waitUntil { s.queuedMessages.map(\.text) == ["next thing"] })
        #expect(!s.messages.contains { texts($0) == "next thing" }, "its bubble went; the queue card holds it")
        #expect(h.notices.contains(SteerRule.failedNotice))
        await h.emit([h.event("message.delta", ["text": ", almost done"])])
        #expect(tail(s, 2) == ["user: first", "bot: Working on it, almost done"], "the reply carried on in its own bubble")
        await h.emit([h.event("message.complete", ["text": "Working on it, almost done", "status": "complete"]),
                      h.event("session.info", ["running": false])])
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 2 })
        #expect(h.client.calls("prompt.submit").last?.params["text"] == "next thing")
        #expect(h.client.calls("prompt.submit").last?.params["queued"] == true)
        #expect(s.queuedMessages.isEmpty)
    }

    @Test func heldForTheNextTurnItMovesToTheEnd() async throws {
        let (h, s) = try await busy { p in ["status": "queued", "text": p["text"] ?? ""] }
        s.send("then summarize")
        #expect(await waitUntil { s.messages.last?.isPending == false })
        #expect(s.queuedMessages.isEmpty, "the gateway holds it, not the phone")
        // The running reply isn't answering it: it goes on in its own bubble, and the message stays the newest row.
        await h.emit([h.event("message.delta", ["text": " still"])])
        #expect(tail(s, 3) == ["user: first", "bot: Working on it still", "user: then summarize"])
        #expect(h.client.calls("prompt.submit").count == 1)
    }

    @Test func aGatewayWithoutRedirectIsAskedOnceThenEverythingQueues() async throws {
        let (h, s) = try await busy { _ in throw RPCError(code: 4010, message: "agent does not support active-turn redirect", data: nil) }
        s.send("one")
        #expect(await waitUntil { s.queuedMessages.map(\.text) == ["one"] })
        #expect(s.redirectUnsupported)
        s.send("two")
        #expect(s.queuedMessages.map(\.text) == ["one", "two"], "queued at once, no second redirect")
        try? await Task.sleep(for: .milliseconds(80))
        #expect(h.client.calls("session.redirect").count == 1)
    }

    @Test func twoQuickMessagesGoOutInTypingOrder() async throws {
        let (h, s) = try await busy { p in
            // The first answer is slow: the second must still go out after it.
            if p["text"] == "a" { try? await Task.sleep(for: .milliseconds(120)) }
            return ["status": "redirected", "text": p["text"] ?? ""]
        }
        s.send("a")
        s.send("b")
        #expect(tail(s, 2) == ["user: a", "user: b"])
        #expect(await waitUntil { h.client.calls("session.redirect").count == 2 })
        #expect(h.client.calls("session.redirect").map { $0.params["text"] } == ["a", "b"])
        #expect(await waitUntil { s.messages.suffix(2).allSatisfy { !$0.isPending } })
    }

    @Test func slashCommandsSkillsAndStopsKeepToTheQueue() async throws {
        let (_, s) = try await busy { p in ["status": "redirected", "text": p["text"] ?? ""] }
        #expect(s.steersTyped("hello", display: nil, attachments: []))
        #expect(!s.steersTyped("/compress", display: nil, attachments: []), "a slash command")
        #expect(!s.steersTyped("Run the skill", display: "/pdf report.pdf", attachments: []), "a skill shows other words")
        #expect(!s.steersTyped("   ", display: nil, attachments: []))
        s.stop()
        #expect(!s.steersTyped("hello", display: nil, attachments: []), "a stopped reply is unwinding")
    }

    @Test func aToolRunningWhenSteeredFinishesInItsOwnBubble() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        h.client.onCall { method, p in method == "session.redirect" ? ["status": "redirected", "text": p["text"] ?? ""] : [:] }
        // A turn this phone didn't send (the desktop's, a server-drained queue): no bubble of ours anchors it.
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Running the tests"]),
                      h.event("tool.start", ["tool_id": "t1", "name": "terminal", "args": ["command": "npm test"]])])
        #expect(s.isRunning)
        s.send("skip the slow ones")
        #expect(await waitUntil { s.messages.last?.isPending == false })
        await h.emit([h.event("tool.complete", ["tool_id": "t1", "name": "terminal", "result": ["stdout": "ok", "exit_code": 0]]),
                      h.event("message.delta", ["text": "Skipped them."])])
        let calls = s.messages.flatMap { m in m.parts.compactMap { if case .tool(let c) = $0, c.id == "t1" { return (m.id, c) } else { return nil } } }
        #expect(calls.count == 1, "the call shows once")
        let sealed = try #require(s.messages.firstIndex { m in m.parts.contains { if case .tool(let c) = $0 { return c.id == "t1" } else { return false } } })
        let steer = try #require(s.messages.firstIndex { texts($0) == "skip the slow ones" })
        #expect(sealed < steer, "the call stays above the steer")
        #expect(calls.first?.1.state == .done)
        #expect(s.messages.last.map(texts) == "Skipped them.")
    }

    @Test func commandReturnStillQueues() async throws {
        let (h, s) = try await busy { p in ["status": "redirected", "text": p["text"] ?? ""] }
        s.queuesNextSend = true
        s.send("after this")
        #expect(s.queuedMessages.map(\.text) == ["after this"])
        #expect(!s.queuesNextSend, "read once")
        s.send("into the reply")
        #expect(s.queuedMessages.map(\.text) == ["after this"])
        #expect(await waitUntil { h.client.calls("session.redirect").count == 1 })
        #expect(h.client.calls("session.redirect").first?.params["text"] == "into the reply")
    }

    @Test func idleSendsAreUnchanged() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        #expect(await h.open())
        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming"] : [:] }
        #expect(!s.steersTyped("hello", display: nil, attachments: []))
        s.send("hello")
        #expect(await waitUntil { h.client.calls("prompt.submit").count == 1 })
        #expect(h.client.calls("session.redirect").isEmpty)
    }

    // MARK: Opened mid-turn: the gateway's snapshot names the steers (`inflight.corrections`)

    /// A chat opened while "Fix the tests" runs, steered with "also the README" after 23 characters of the reply.
    private func openedMidTurn(stored: [JSONValue], assistant: String) async throws -> (ChatHarness, LiveChatSession) {
        let h = try ChatHarness()
        let base = Array((try ChatFixtures.json("perf-page-latest-24.json")["messages"]?.array ?? []).suffix(20))
        let now = Date().timeIntervalSince1970
        h.setPage("24", rows: base + stored.map { row in
            var r = row.object ?? [:]
            r["timestamp"] = .number(now - 30)
            return .object(r)
        }, hasMore: true)
        var resume = try ChatFixtures.json("perf-resume.json")["result"]?.object ?? [:]
        resume["running"] = true
        resume["status"] = "running"
        resume["turn_started_at"] = .number(now - 40)
        resume["inflight"] = ["user": "Fix the tests", "assistant": .string(assistant), "streaming": true,
                              "corrections": ["also the README"], "correction_offsets": [23]]
        let result = JSONValue.object(resume)
        h.client.onCall { method, _ in
            switch method {
            case "session.resume", "session.activate": return result
            case "session.active_list": return ["sessions": []]
            case "session.events.since": return ["events": [], "latest_seq": 0, "truncated": false, "epoch": "fixture-epoch"]
            default: return [:]
            }
        }
        let s = h.make()
        #expect(await h.open())
        s.flushChanges()
        return (h, s)
    }

    @Test func openedMidTurnBeforeTheSteerIsStoredShowsItInPlace() async throws {
        let (h, s) = try await openedMidTurn(stored: [["role": "user", "content": "Fix the tests", "row_id": 9000]],
                                             assistant: "Looking at the failuresREADME is next")
        #expect(tail(s, 4) == ["user: Fix the tests", "bot: Looking at the failures", "user: also the README", "bot: README is next"])
        #expect(s.isRunning)
        await h.emit([h.event("message.delta", ["text": ", then done."])])
        #expect(tail(s, 4) == ["user: Fix the tests", "bot: Looking at the failures", "user: also the README", "bot: README is next, then done."])
    }

    @Test func openedMidTurnWithTheSteerStoredShowsEachOnce() async throws {
        let (h, s) = try await openedMidTurn(stored: [["role": "user", "content": "Fix the tests", "row_id": 9000],
                                                       ["role": "assistant", "content": "Looking at the failures", "row_id": 9001],
                                                       ["role": "user", "content": "also the README", "row_id": 9002]],
                                             assistant: "Looking at the failures")
        let shown = s.messages.map(texts)
        #expect(shown.filter { $0 == "Fix the tests" }.count == 1, "the steer is not taken for the turn's prompt")
        #expect(shown.filter { $0 == "also the README" }.count == 1)
        #expect(shown.filter { $0 == "Looking at the failures" }.count == 1)
        #expect(tail(s, 3) == ["user: Fix the tests", "bot: Looking at the failures", "user: also the README"])
        // The reply to the steer arrives below it, and the turn's end leaves each row once.
        await h.emit([h.event("message.delta", ["text": "README fixed."])])
        #expect(tail(s, 4) == ["user: Fix the tests", "bot: Looking at the failures", "user: also the README", "bot: README fixed."])
        let base = Array((try ChatFixtures.json("perf-page-latest-24.json")["messages"]?.array ?? []).suffix(20))
        h.setPage("24", rows: base + [["role": "user", "content": "Fix the tests", "row_id": 9000],
                                      ["role": "assistant", "content": "Looking at the failures", "row_id": 9001],
                                      ["role": "user", "content": "also the README", "row_id": 9002],
                                      ["role": "assistant", "content": "README fixed.", "row_id": 9003]], hasMore: true)
        await h.emit([h.event("message.complete", ["text": "README fixed.", "status": "complete",
                                                   "persisted_turn": ["final_assistant_row_id": 9003]]),
                      h.event("session.info", ["running": false])])
        #expect(await waitUntil { s.refreshTask == nil && !s.isRunning && s.messages.last?.rowId == 9003 })
        try? await Task.sleep(for: .milliseconds(80))
        s.flushChanges()
        #expect(tail(s, 4) == ["user: Fix the tests", "bot: Looking at the failures", "user: also the README", "bot: README fixed."])
        #expect(s.messages.map(texts).filter { $0 == "README fixed." }.count == 1)
    }
}

