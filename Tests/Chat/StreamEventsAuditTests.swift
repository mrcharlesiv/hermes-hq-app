// Live stream fixes from the build 863 audit (chat logic): a late turn end from an earlier turn, the error after a
// failed resume held during a reconnect, a tool call with no id, a sealed reply written over, and the activity shelf's
// delegate stand-ins and open helper detail after a rebind.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

private func toolParts(_ m: ChatMessage?) -> [ToolCall] {
    (m?.parts ?? []).compactMap { if case .tool(let c) = $0 { return c } else { return nil } }
}

@Suite("Live stream events (audit 863)", .serialized)
@MainActor
struct StreamEventsAuditTests {
    /// The late end of a turn a heartbeat settled early lands after the next send: it names the earlier prompt, so the
    /// running turn keeps Working… and no copy of the old reply is drawn under the new message.
    @Test func anEarlierTurnsLateEndLeavesTheNextTurnRunning() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.turnEndReadDelay = .seconds(10)
        #expect(await h.open())
        h.client.onCall { method, params in
            method == "prompt.submit"
                ? ["status": "streaming", "user_row_id": params["text"] == "first" ? 5000 : 5002]
                : [:]
        }
        s.send("first")
        #expect(await waitUntil { h.lastUser?.rowId == 5000 })
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Reply one"]),
                      h.event("session.info", ["running": false])])                   // settled before its end
        #expect(!s.isRunning)
        s.send("second")
        #expect(await waitUntil { h.lastUser?.rowId == 5002 })
        await h.emit([h.event("message.complete", ["text": "Reply one", "status": "complete",
                                                   "persisted_turn": ["user_row_id": 5000, "final_assistant_row_id": 5001]])])
        s.flushChanges()
        #expect(s.isRunning)
        let second = try #require(s.messages.lastIndex { $0.role == .user && $0.plainText == "second" })
        #expect(!s.messages[(second + 1)...].contains { $0.role == .assistant })
        #expect(s.messages.filter { $0.plainText == "Reply one" }.count == 1)
    }

    /// A resume whose loading failed while frames were held (an open or reconnect): the error that follows is still this
    /// chat's, so the turn ends with it instead of showing Working… for good.
    @Test func theErrorAfterAFailedResumeHeldDuringAReconnectEndsTheTurn() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.turnEndReadDelay = .seconds(10)
        #expect(await h.open())
        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming"] : [:] }
        s.send("go")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Starting"])])
        #expect(s.isRunning)
        s.parking = true                                                        // a reconnect holds frames
        await h.emit([h.event("session.resume_progress", ["status": "failed"]),
                      h.event("error", ["message": "Couldn't load this chat's history."])])
        s.parking = false
        s.releaseParked()
        s.flushChanges()
        #expect(!s.isRunning)
        #expect(s.runtimeSessionId == nil)
        #expect(s.messages.contains { $0.error == "Couldn't load this chat's history." })
    }

    /// A tool call the gateway sent with no `tool_id`, first thing in the reply: its finish settles that row.
    @Test func aToolCallWithNoIdShowsAsOneRow() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.turnEndReadDelay = .seconds(10)
        #expect(await h.open())
        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming"] : [:] }
        s.send("go")
        await h.emit([h.event("message.start"),
                      h.event("tool.start", ["name": "terminal", "args": ["command": "ls"]]),
                      h.event("tool.complete", ["name": "terminal", "result": ["stdout": "a", "exit_code": 0]])])
        let calls = toolParts(h.assistant)
        #expect(calls.count == 1)
        #expect(calls.first?.state == .done)
    }

    /// A reply sealed early by a heartbeat that then got its end is done with: a later end with no start of its own (a
    /// cut-short replay) never writes over it.
    @Test func aSealedReplyIsNotWrittenOverByALaterTurnsEnd() async throws {
        let h = try ChatHarness()
        try h.setPage("24", "perf-page-latest-24.json")
        let s = h.make()
        s.turnEndReadDelay = .seconds(10)
        #expect(await h.open())
        h.client.onCall { method, _ in method == "prompt.submit" ? ["status": "streaming"] : [:] }
        s.send("first")
        await h.emit([h.event("message.start"), h.event("message.delta", ["text": "Reply one"]),
                      h.event("session.info", ["running": false]),
                      h.event("message.complete", ["text": "Reply one", "status": "complete"])])
        let reply = try #require(h.assistant)
        #expect(reply.plainText == "Reply one")
        await h.emit([h.event("message.complete", ["text": "Something else entirely", "status": "complete"])])
        s.flushChanges()
        #expect(s.messages.first { $0.id == reply.id }?.plainText == "Reply one")
    }
}

@Suite("Activity after a rebind and at a turn's end (audit 863)", .serialized)
@MainActor
struct ActivityAuditTests {
    let client = FakeGatewayClient()
    let store: ActivityStore
    let rid = "5cc537d1"

    init() {
        store = ActivityStore(client: client, frameMode: .manual)
        store.listBase = 0.05
        store.listMax = 0.2
        store.staleSettle = 0.01
        store.stalePoll = 60
        store.start()
    }

    func event(_ type: String, _ payload: JSONValue, sid: String? = nil) {
        store.handle(GatewayEvent(type: type, sessionId: sid ?? rid, seq: nil, payload: payload))
    }

    /// A delegate stand-in whose `tool.complete` was missed ends with its turn instead of saying "running" for good.
    @Test func aDelegateStandInEndsWithItsTurn() {
        store.bind(runtimeId: rid, profile: "default", storedId: "s1")
        event("message.start", .null)
        event("tool.start", ["tool_id": "call_d1", "name": "delegate_task", "args": ["tasks": [["goal": "A"]]]])
        #expect(store.activity(rid).liveSubagents.count == 1)
        event("message.complete", ["text": "done"])
        #expect(store.activity(rid).liveSubagents.isEmpty)
        #expect(!store.hasLiveWork(profile: "default"))
    }

    /// An open helper's detail follows its chat to a new runtime id: the detail poll asks about the new id.
    @Test func anOpenHelpersDetailFollowsARebind() async {
        store.bind(runtimeId: rid, profile: "default", storedId: "s1")
        store.setVisible(runtimeId: rid, openSubagent: "sa_1")
        #expect(await waitUntil { client.calls("subagent.tail").contains { $0.params["session_id"] == "5cc537d1" } })
        store.bind(runtimeId: "aaaa0001", profile: "default", storedId: "s1")
        #expect(await waitUntil { client.calls("subagent.tail").contains { $0.params["session_id"] == "aaaa0001" } })
    }
}
