// The ActivityStore against a scripted client (docs/spec/1x-activity.md §3.2, §4.4, §5, §6): event rules, reads,
// strict params, the stale-claim check, goal actions, and the live chat's reasoning timing.

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

@MainActor
@Suite("Activity · store", .serialized)
struct ActivityStoreTests {
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

    @Test func subagentEventsBuildTheRosterAndStopClearsIt() {
        store.bind(runtimeId: rid, profile: "default", storedId: "s1")
        event("subagent.start", ["goal": "Read", "task_count": 1, "task_index": 0, "subagent_id": "sa_1", "status": "running"])
        event("subagent.tool", ["goal": "Read", "task_count": 1, "task_index": 0, "subagent_id": "sa_1", "tool_name": "read_file", "tool_preview": "A.md"])
        #expect(store.activity(rid).liveSubagents.count == 1)
        #expect(store.hasLiveWork(profile: "default"))
        store.stopped(runtimeId: rid)
        #expect(store.activity(rid).subagents.isEmpty)
        // Late frames of the stopped turn are dropped until the next send.
        event("subagent.start", ["goal": "Late", "task_count": 1, "task_index": 0, "subagent_id": "sa_2"])
        #expect(store.activity(rid).subagents.isEmpty)
        store.setInterrupted(runtimeId: rid, false)
        event("subagent.start", ["goal": "Next", "task_count": 1, "task_index": 0, "subagent_id": "sa_3"])
        #expect(store.activity(rid).subagents.count == 1)
    }

    @Test func eventsForUnboundChatsAreIgnoredAndRemintMovesState() {
        event("subagent.start", ["goal": "x", "task_count": 1, "task_index": 0, "subagent_id": "a"], sid: "other")
        #expect(store.activity("other").subagents.isEmpty)
        store.bind(runtimeId: rid, profile: "default", storedId: "s1")
        event("subagent.start", ["goal": "x", "task_count": 1, "task_index": 0, "subagent_id": "a"])
        store.bind(runtimeId: "aaaa0001", profile: "default", storedId: "s1")
        #expect(store.activity("aaaa0001").subagents.count == 1)
        #expect(!store.isBound(rid))
    }

    @Test func delegateStandInsUntilANativeEvent() {
        store.bind(runtimeId: rid, profile: "default", storedId: "s1")
        event("message.start", .null)
        event("tool.start", ["tool_id": "call_d1", "name": "delegate_task", "args": ["tasks": [["goal": "A"], ["goal": "B"]]]])
        #expect(store.activity(rid).subagents.map(\.id) == ["delegate-tool:call_d1:0", "delegate-tool:call_d1:1"])
        event("subagent.start", ["goal": "A", "task_count": 2, "task_index": 0, "subagent_id": "sa_1", "status": "running"])
        #expect(store.activity(rid).subagents.map(\.id) == ["sa_1"])
        #expect(store.activity(rid).nativeSubagentEvents)
    }

    @Test func todoEventsRevisionsAndTurnEnd() {
        store.bind(runtimeId: rid, profile: "default", storedId: "s1")
        event("todo.updated", ["todos": [["id": "1", "content": "Read", "status": "in_progress"], ["id": "2", "content": "Write", "status": "pending"]], "revision": 1])
        #expect(store.activity(rid).liveTodos?.count == 2)
        event("todo.updated", ["todos": [["id": "1", "content": "Read", "status": "completed"]], "revision": 3])
        event("todo.updated", ["todos": [["id": "1", "content": "Read", "status": "pending"]], "revision": 2])
        #expect(store.activity(rid).liveTodos?.first?.status == .completed)
        var clock = Date().timeIntervalSince1970
        store.now = { clock }
        clock += 5
        store.expireTodos()
        #expect(store.activity(rid).liveTodos == nil)
        #expect(store.activity(rid).retainedTodos.count == 1)
        event("tool.start", ["name": "todo", "args": ["todos": [["id": "9", "content": "Plan", "status": "in_progress"]]]])
        #expect(store.activity(rid).liveTodos?.first?.id == "9")
        event("message.complete", ["text": "done"])
        #expect(store.activity(rid).liveTodos == nil)
    }

    @Test func resumeTodoStateWhileIdleKeepsOnlyThePreviousList() {
        store.bind(runtimeId: rid, profile: "default", storedId: "s1")
        store.applyResume(["session_id": .string(rid), "running": false,
                           "todo_state": ["todos": [["id": "1", "content": "A", "status": "pending"], ["id": "2", "content": "B", "status": "completed"]], "revision": 5]],
                          runtimeId: rid)
        #expect(store.activity(rid).liveTodos == nil)
        #expect(TodoRules.chipWords(store.activity(rid).retainedTodos, previous: true) == "Previous tasks 1/2")
    }

    @Test func listReadsUseStrictParamsAndReconcile() async {
        let roster = Mutex<JSONValue>(["subagents": [["subagent_id": "sa_1", "goal": "Read", "status": "running", "started_at": 100.0,
                                                       "last_tool": "read_file", "accepting_steer": true]], "delegations": []])
        client.onCall { method, _ in
            switch method {
            case "subagent.list": return roster.withLock { $0 }
            case "session.control.read": throw RPCError(code: -32601, message: "Method not found", data: nil)
            default: return .object([:])
            }
        }
        store.bind(runtimeId: rid, profile: "default", storedId: "s1")
        store.setVisible(runtimeId: rid, openSubagent: nil)
        #expect(await waitUntil { store.activity(rid).subagents.count == 1 })
        let list = client.calls("subagent.list").first
        #expect(list?.params == ["session_id": .string(rid), "profile": "default"])
        // A live child polls; when the roster empties, the child goes and the polls stop.
        roster.withLock { $0 = ["subagents": [], "delegations": []] }
        #expect(await waitUntil(timeout: .seconds(3)) { store.activity(rid).subagents.isEmpty })
        let calls = client.calls("subagent.list").count
        try? await Task.sleep(for: .milliseconds(400))
        #expect(client.calls("subagent.list").count == calls)
        // -32601 on control: no goal on this gateway, never read again.
        #expect(store.activity(rid).control.capability == .unsupported)
    }

    /// §16 check 12 (R:src/subagent-poll-backoff.test.ts): a roster that changes nothing doubles the wait (5 → 30 s,
    /// here 0.05 → 0.4 s); a change resets it; none at all once no child is live.
    @Test func listPollsBackOffAndStop() async {
        store.listBase = 0.05
        store.listMax = 0.4
        let roster = Mutex<JSONValue>(["subagents": [["subagent_id": "a", "goal": "g", "status": "running", "started_at": 1.0]], "delegations": []])
        client.onCall { method, _ in
            if method == "subagent.list" { return roster.withLock { $0 } }
            return .object([:])
        }
        store.bind(runtimeId: rid, profile: "default", storedId: "s1")
        store.setVisible(runtimeId: rid, openSubagent: nil)
        event("subagent.start", ["goal": "g", "task_count": 1, "task_index": 0, "subagent_id": "a", "status": "running"])
        try? await Task.sleep(for: .seconds(1.5))
        let steady = client.calls("subagent.list").count
        // Flat 0.05 s polling would make ~30 reads; backing off makes ~7 (hydrate, loop start, .05, .15, .35, .75, 1.15).
        #expect(steady <= 9, "reads while nothing changed: \(steady)")
        #expect(steady >= 4)
        roster.withLock { $0 = ["subagents": [["subagent_id": "a", "goal": "g", "status": "running", "started_at": 1.0, "last_tool": "terminal", "tool_count": 2],
                                               ["subagent_id": "b", "goal": "h", "status": "running", "started_at": 2.0]], "delegations": []] }
        #expect(await waitUntil(timeout: .seconds(1)) { store.activity(rid).subagents.count == 2 })
        let afterChange = client.calls("subagent.list").count
        try? await Task.sleep(for: .milliseconds(120))
        #expect(client.calls("subagent.list").count > afterChange, "back to the base rate after a change")
        roster.withLock { $0 = ["subagents": [], "delegations": []] }
        #expect(await waitUntil(timeout: .seconds(2)) { store.activity(rid).liveSubagents.isEmpty })
        let ended = client.calls("subagent.list").count
        try? await Task.sleep(for: .milliseconds(600))
        #expect(client.calls("subagent.list").count == ended, "no polls once no child is live")
    }

    @Test func staleClaimIsDroppedByDelegationStatus() async {
        client.onCall { method, params in
            if method == "delegation.status" { return ["active": [], "paused": false, "max_spawn_depth": 1, "max_concurrent_children": 3] }
            if method == "session.control.read" { throw RPCError(code: 5031, message: "busy", data: nil) }
            return .object([:])
        }
        store.bind(runtimeId: rid, profile: "default", storedId: "s1")
        event("subagent.start", ["goal": "x", "task_count": 1, "task_index": 0, "subagent_id": "sa_9", "status": "running"])
        #expect(store.hasLiveWork(profile: "default"))
        await store.staleCheck()
        #expect(!store.hasLiveWork(profile: "default"))
        #expect(client.calls("delegation.status").first?.params == ["profile": "default"])
    }

    @Test func goalReadAndActions() async throws {
        let snapshot = ControlRulesTests.snapshot(ControlRulesTests.goal)
        client.onCall { method, params in
            switch method {
            case "session.control.read": return ["control": snapshot]
            case "session.control":
                var goal = ControlRulesTests.goal.object!
                goal["status"] = "paused"
                return ["control": ControlRulesTests.snapshot(.object(goal)),
                        "dispatch": ["type": "exec", "output": "⏸ Goal paused", "notice": nil, "message": nil, "display": nil]]
            default: return .object([:])
            }
        }
        store.bind(runtimeId: rid, profile: "default", storedId: "s1")
        #expect(await waitUntil { store.activity(rid).goal != nil })
        let dispatch = try await store.runControl(runtimeId: rid, action: "goal.pause", args: [:])
        #expect(dispatch.type == "exec")
        #expect(store.activity(rid).goal?.status == .paused)
        #expect(client.calls("session.control").first?.params == ["session_id": .string(rid), "profile": "default", "action": "goal.pause", "args": [:]])
        // An update event replaces it; a malformed one is ignored.
        event("session.control.update", ["control": snapshot])
        #expect(store.activity(rid).goal?.status == .active)
        event("session.control.update", ["control": ["goal": "nope"]])
        #expect(store.activity(rid).goal?.status == .active)
    }

    @Test func steerAndStopAnswers() async {
        client.onCall { method, params in
            switch method {
            case "subagent.steer": return ["status": "queued", "subagent_id": params["subagent_id"] ?? nil, "text": params["text"] ?? nil]
            case "subagent.interrupt": return ["found": false, "subagent_id": params["subagent_id"] ?? nil]
            default: return .object([:])
            }
        }
        store.bind(runtimeId: rid, profile: "default", storedId: "s1")
        #expect(await store.steer(runtimeId: rid, subagentId: "sa_1", text: "  Only open issues ") == .queued)
        #expect(client.calls("subagent.steer").first?.params["text"] == "Only open issues")
        #expect(await store.steer(runtimeId: rid, subagentId: "sa_1", text: "   ") == .rejected)
        #expect(client.calls("subagent.steer").count == 1)
        #expect(await store.interrupt(runtimeId: rid, subagentId: "sa_1") == false)
    }
}

@MainActor
@Suite("Activity · reasoning timing")
struct ReasoningTimingTests {
    @Test func thoughtForSecondsThenBrieflyThenHistory() throws {
        let client = FakeGatewayClient()
        let session = LiveChatSession(client: client, account: client.account, profile: "default", storedSessionId: "s1", title: "Hermes",
                                      head: nil, cache: makeTempCache(), resolveSessionId: nil, frameMode: .manual)
        var now = Date(timeIntervalSince1970: 1000)
        session.activityLink.clock = { now }
        session.messages = [ChatMessage(id: "m1", role: .assistant, parts: [.reasoning("thinking")], timestamp: nil, rowId: nil, isStreaming: true)]
        session.rebuildIndex()
        session.turn.streamId = "m1"
        session.noteReasoningTimes()
        now = now.addingTimeInterval(7.4)
        session.messages[0].parts.append(.tool(ToolCall(id: "t", name: "terminal", title: "t", argsText: nil, summary: nil, state: .running, durationSeconds: nil)))
        session.noteReasoningTimes()
        #expect(session.reasoningSeconds(messageId: "m1") == [0: 7])
        // A second, brief thought.
        session.messages[0].parts.append(.reasoning("more"))
        session.noteReasoningTimes()
        now = now.addingTimeInterval(0.4)
        session.messages[0].isStreaming = false
        session.noteReasoningTimes()
        #expect(session.reasoningSeconds(messageId: "m1")[2] == 0)
        #expect(session.reasoningSeconds(messageId: "history").isEmpty)
    }
}
