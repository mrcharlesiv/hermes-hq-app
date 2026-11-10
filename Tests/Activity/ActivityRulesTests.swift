// Unit ports of the web's activity tests (docs/spec/1x-activity.md §16 checks 1–9): tool lines, subagent roster rules,
// task lists, the goal snapshot, delegate rows, diffs, provider waits, steps state.

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Activity · tool lines (R:src/ui-chat/tool-line.test.ts)")
struct ToolLineTests {
    func line(_ name: String, _ args: JSONValue?) -> ToolLine { ToolLines.line(name, args: args) }

    @Test func wordsBuiltInToolsTheWayHermesDoes() {
        #expect(line("web_search", ["query": "chat export  markdown"]) == ToolLine(emoji: "🔍", text: "Searching the web for chat export markdown"))
        #expect(line("search_files", ["pattern": "exportChat", "path": "/src"]) == ToolLine(emoji: "🔎", text: "Searching files for exportChat"))
        #expect(line("browser_navigate", ["url": "https://www.example.org/changelog/"]) == ToolLine(emoji: "🌐", text: "Browsing example.org/changelog"))
        #expect(line("web_extract", ["urls": ["https://example.org/a"]]) == ToolLine(emoji: "📄", text: "Reading example.org/a"))
    }

    @Test func namesAFileByItsLastPathPart() {
        #expect(line("read_file", ["path": "/home/hermes/app/CHANGELOG.md"]) == ToolLine(emoji: "📖", text: "Reading CHANGELOG.md"))
        #expect(line("write_file", .string(#"{"path":"/a/b/notes.md","content":"x"}"#)) == ToolLine(emoji: "✍️", text: "Writing notes.md"))
        #expect(line("patch", ["path": "C:\\repo\\main.ts"]) == ToolLine(emoji: "🔧", text: "Editing main.ts"))
    }

    @Test func showsACommandAsCode() {
        #expect(line("terminal", ["command": "npm test"]) == ToolLine(emoji: "💻", text: "terminal", code: "npm test"))
        #expect(line("execute_code", ["code": "print(1)"]) == ToolLine(emoji: "🐍", text: "Running code", code: "print(1)"))
    }

    @Test func keepsAnUnknownToolUnderItsName() {
        #expect(line("mcp_github_create_issue", ["title": "Bug"]) == ToolLine(emoji: "⚙️", text: "mcp_github_create_issue…"))
        #expect(line("custom_tool", ["query": "q"]) == ToolLine(emoji: "⚙️", text: "custom_tool: “q”"))
    }

    @Test func survivesPartialOrMissingArguments() {
        #expect(line("terminal", .string(#"{"comm"#)) == ToolLine(emoji: "💻", text: "Running"))
        #expect(line("web_search", nil) == ToolLine(emoji: "🔍", text: "Searching the web"))
        #expect(line("memory", ["action": "add", "content": "secret"]) == ToolLine(emoji: "🧠", text: "Updating memory"))
        #expect(line("delegate_task", ["tasks": [["goal": "a"], ["goal": "b"]]]) == ToolLine(emoji: "🔀", text: "Delegating 2 tasks"))
    }

    @Test func statusWordsUseTheCodesFirstLine() {
        #expect(line("terminal", ["command": "npm test\nnpm run lint"]).statusWords == "💻 npm test")
        #expect(line("web_search", ["query": "kv cache"]).statusWords == "🔍 Searching the web for kv cache")
    }
}

@Suite("Activity · subagent roster (V:store/subagents.test.ts)")
struct SubagentRulesTests {
    typealias P = [String: JSONValue]

    @Test func idFallsBackToParentIndexAndGoal() {
        #expect(SubagentRules.idOf(["subagent_id": "sa_1"]) == "sa_1")
        #expect(SubagentRules.idOf(["goal": "Scan", "task_index": 2]) == "root:2:Scan")
        #expect(SubagentRules.idOf(["goal": "Scan", "parent_id": "p"]) == "p:0:Scan")
    }

    @Test func upsertKeepsTerminalStatusStable() {
        var r = SubagentRoster()
        r.upsert(["goal": "scan files", "status": "running", "subagent_id": "a1", "task_index": 0], createIfMissing: true, eventType: nil, now: 1)
        r.upsert(["goal": "scan files", "status": "completed", "subagent_id": "a1", "summary": "done"], createIfMissing: true, eventType: nil, now: 2)
        r.upsert(["goal": "scan files", "status": "running", "subagent_id": "a1", "text": "late"], createIfMissing: true, eventType: nil, now: 3)
        #expect(r.items.first?.status == .completed)
        #expect(r.items.first?.summary == "done")
    }

    @Test func createsOnlyOnSpawnOrStart() {
        var r = SubagentRoster()
        let created = r.upsert(["subagent_id": "x", "status": "running"], createIfMissing: false, eventType: "subagent.tool", now: 1)
        #expect(!created)
        #expect(r.items.isEmpty)
    }

    @Test func retiredChildrenNeverComeBack() {
        var r = SubagentRoster()
        let finished: P = ["subagent_id": "finished", "goal": "Finished task", "status": "running"]
        let live: P = ["subagent_id": "live", "goal": "Background task", "status": "queued"]
        r.upsert(finished, createIfMissing: true, eventType: "subagent.start", now: 1)
        r.upsert(live, createIfMissing: true, eventType: "subagent.spawn_requested", now: 1)
        var done = finished; done["status"] = "completed"; done["summary"] = "Done"
        r.upsert(done, createIfMissing: false, eventType: "subagent.complete", now: 2)
        r.pruneFinished()
        let pruned = r.items
        r.reconcile(children: [finished, live], now: 3)
        r.upsert(finished, createIfMissing: true, eventType: "subagent.start", now: 4)
        #expect(r.items == pruned)
        #expect(r.items.map(\.id) == ["live"])
    }

    @Test func statusMappingFailsClosedOnCompletion() {
        var r = SubagentRoster()
        for (id, status) in [("a", "timeout"), ("b", "error"), ("c", "cancelled"), ("d", "canceled"), ("e", "running"), ("f", "mystery")] {
            r.upsert(["goal": .string(id), "status": "running", "subagent_id": .string(id)], createIfMissing: true, eventType: "subagent.start", now: 1)
            r.upsert(["status": .string(status), "subagent_id": .string(id)], createIfMissing: false, eventType: "subagent.complete", now: 2)
        }
        let byId = Dictionary(uniqueKeysWithValues: r.items.map { ($0.id, $0.status) })
        #expect(byId == ["a": .failed, "b": .failed, "c": .interrupted, "d": .interrupted, "e": .failed, "f": .failed])
        #expect(r.liveCount == 0)
        // A live event with an unknown status stays lenient.
        r.upsert(["goal": "g", "status": "running", "subagent_id": "u2"], createIfMissing: true, eventType: "subagent.start", now: 3)
        r.upsert(["status": "some_future_live_status", "subagent_id": "u2", "text": "still"], createIfMissing: false, eventType: "subagent.progress", now: 4)
        #expect(r.items.last?.status == .running)
    }

    @Test func timeoutSynthesisesItsReason() {
        var r = SubagentRoster()
        r.upsert(["goal": "scan", "status": "running", "subagent_id": "t1"], createIfMissing: true, eventType: "subagent.start", now: 1)
        r.upsert(["status": "timeout", "subagent_id": "t1", "duration_seconds": 612.3], createIfMissing: false, eventType: "subagent.complete", now: 2)
        #expect(r.items[0].status == .failed)
        #expect(r.items[0].summary == "Timed out after 612.3s")
        r.upsert(["goal": "x", "status": "running", "subagent_id": "t2"], createIfMissing: true, eventType: "subagent.start", now: 1)
        r.upsert(["status": "timeout", "subagent_id": "t2", "duration_seconds": 9], createIfMissing: false, eventType: "subagent.complete", now: 2)
        #expect(r.items[1].summary == "Timed out after 9s")
    }

    @Test func streamCapturesToolThinkingProgressAndSummary() {
        var r = SubagentRoster()
        r.upsert(["goal": "scan files", "status": "queued", "subagent_id": "a1"], createIfMissing: true, eventType: "subagent.spawn_requested", now: 1)
        r.upsert(["status": "running", "subagent_id": "a1", "tool_name": "search_files", "tool_preview": "pattern=hermes"],
                 createIfMissing: false, eventType: "subagent.tool", now: 2)
        r.upsert(["status": "running", "subagent_id": "a1", "text": "plan the search order"], createIfMissing: false, eventType: "subagent.thinking", now: 3)
        r.upsert(["status": "running", "subagent_id": "a1", "text": "found candidate matches"], createIfMissing: false, eventType: "subagent.progress", now: 4)
        r.upsert(["status": "completed", "subagent_id": "a1", "summary": "search complete"], createIfMissing: false, eventType: "subagent.complete", now: 5)
        let item = r.items[0]
        #expect(item.stream.map(\.kind) == [.tool, .thinking, .progress, .summary])
        #expect(item.stream[0].text == "Search Files(\"pattern=hermes\")")
        #expect(item.stream[3].text == "search complete")
    }

    @Test func streamIsCappedAndDeduped() {
        var r = SubagentRoster()
        r.upsert(["goal": "g", "status": "running", "subagent_id": "s"], createIfMissing: true, eventType: "subagent.start", now: 0)
        for i in 0..<30 {
            r.upsert(["status": "running", "subagent_id": "s", "text": .string("step \(i)")], createIfMissing: false, eventType: "subagent.progress", now: Double(i))
            r.upsert(["status": "running", "subagent_id": "s", "text": .string("step \(i)")], createIfMissing: false, eventType: "subagent.progress", now: Double(i))
        }
        #expect(r.items[0].stream.count == 24)
        #expect(r.items[0].stream.last?.text == "step 29")
    }

    @Test func formatsToolsAndCompactsPreviews() {
        #expect(SubagentRules.formatTool("read_file", "CHANGELOG.md") == "Read File(\"CHANGELOG.md\")")
        #expect(SubagentRules.formatTool("terminal") == "Terminal")
        let long = String(repeating: "a ", count: 200)
        let compacted = SubagentRules.compact(long)
        #expect(compacted.count == 220)
        #expect(compacted.hasSuffix("…"))
    }

    @Test func turnStartPrunesFinishedAndStopClearsAll() {
        var r = SubagentRoster()
        for (id, status) in [("live-a", "running"), ("live-b", "queued"), ("done", "completed"), ("broken", "failed")] {
            r.upsert(["goal": .string(id), "status": .string(status), "subagent_id": .string(id)], createIfMissing: true, eventType: nil, now: 1)
        }
        r.pruneFinished()
        #expect(Set(r.items.map(\.id)) == ["live-a", "live-b"])
        r.clear()
        #expect(r.items.isEmpty)
    }

    @Test func reconcileKeepsTerminalAndListedSeedsLastToolAndAddsFailedDelegations() {
        var r = SubagentRoster()
        r.upsert(["goal": "a", "status": "running", "subagent_id": "a"], createIfMissing: true, eventType: "subagent.start", now: 1)
        r.upsert(["goal": "b", "status": "running", "subagent_id": "b"], createIfMissing: true, eventType: "subagent.start", now: 1)
        r.upsert(["goal": "c", "status": "completed", "subagent_id": "c"], createIfMissing: true, eventType: nil, now: 1)
        r.reconcile(children: [["subagent_id": "a", "goal": "a", "status": "running", "started_at": 100, "last_tool": "terminal"],
                               ["subagent_id": "n", "goal": "new", "status": "running", "started_at": 200, "last_tool": "read_file"]],
                    failedDelegations: [["delegation_id": "d1", "task_index": 0, "goal": "Audit", "status": "error",
                                         "error": "interrupted", "dispatched_at": 1000, "completed_at": 1300]], now: 5)
        #expect(r.items.map(\.id) == ["a", "c", "n", "delegation:d1:0"])
        #expect(r.items[0].startedAt == 100)
        #expect(r.items[2].stream.map(\.text) == ["Read File"])
        let failed = r.items[3]
        #expect(failed.status == .failed && failed.summary == "interrupted" && failed.durationSeconds == 300)
        // Repeated reads change nothing.
        let before = r
        let again = r.reconcile(children: [["subagent_id": "a", "goal": "a", "status": "running", "started_at": 100, "last_tool": "terminal"],
                                           ["subagent_id": "n", "goal": "new", "status": "running", "started_at": 200, "last_tool": "read_file"]],
                                failedDelegations: [["delegation_id": "d1", "task_index": 0, "goal": "Audit", "error": "interrupted"]], now: 6)
        #expect(!again)
        #expect(r == before)
    }

    @Test func delegateStandInsAndTheirRemoval() {
        let start: JSONValue = ["name": "delegate_task", "tool_id": "call_d1", "args": ["tasks": [["goal": "Read the changelog"], ["goal": "Check issues"]]]]
        let payloads = SubagentRules.delegatePayloads(start, complete: false, sourceEventType: "tool.start")
        #expect(payloads.map { $0["subagent_id"]?.string } == ["delegate-tool:call_d1:0", "delegate-tool:call_d1:1"])
        var r = SubagentRoster()
        for p in payloads { r.upsert(p, createIfMissing: true, eventType: "delegate.running", now: 1) }
        #expect(r.liveCount == 2)
        let done: JSONValue = ["name": "delegate_task", "tool_id": "call_d1", "args": ["goal": "Solo"], "result": ["status": "timeout"]]
        #expect(SubagentRules.delegatePayloads(done, complete: true, sourceEventType: "tool.complete").first?["status"]?.string == "failed")
        r.pruneDelegateStandIns()
        #expect(r.items.isEmpty)
    }

    /// A card's picture opens in the photo viewer when the media cache can key it (an absolute gateway path).
    @Test func cardPicturesWithAnAbsolutePathOpenInThePhotoViewer() {
        #expect(ActivityMedia.opensInPhotoViewer(path: "/Users/ivy/out/chart.png"))
        #expect(ActivityMedia.opensInPhotoViewer(path: "~/out/chart.png"))
        #expect(!ActivityMedia.opensInPhotoViewer(path: "out/chart.png"), "session-relative: its key would miss the session")
        #expect(!ActivityMedia.opensInPhotoViewer(path: "screenshot.png"))
        #expect(!ActivityMedia.opensInPhotoViewer(path: "data:image/png;base64,AAAA"))
        #expect(!ActivityMedia.opensInPhotoViewer(path: ""))
    }

    @Test func statsAndWords() {
        #expect(SubagentRules.formatElapsed(7) == "7s")
        #expect(SubagentRules.formatElapsed(65) == "1:05")
        #expect(SubagentRules.formatElapsed(4500) == "1:15:00")   // never "75:00"
        #expect(SubagentRules.formatDuration(nil) == "")
        #expect(SubagentRules.formatDuration(4.2) == "4.2s")
        #expect(SubagentRules.formatDuration(119.6) == "2m")       // never "1m 60s"
        #expect(SubagentRules.formatDuration(754.3) == "12m 34s")
        #expect(SubagentRules.compactNumber(1230) == "1.2k")
        #expect(SubagentRules.compactNumber(999) == "999")
        #expect(SubagentRules.chipWords(liveCount: 1) == "1 helper")
        #expect(SubagentRules.chipWords(liveCount: 2) == "2 helpers")
        let s = SubagentProgress(id: "a", goal: "g", model: "m", status: .completed, taskCount: 1, taskIndex: 0, startedAt: 0,
                                 updatedAt: 100, durationSeconds: 4.2, inputTokens: 18200, outputTokens: 1300, toolCount: 9)
        #expect(SubagentRules.statsLine(s, now: 130) == "m · 4.0s · 9 tools · 19.5k tok · updated 30s ago")
    }
}

@Suite("Activity · task lists (V:store/todos.ts, V:lib/todos.ts)")
struct TodoRulesTests {
    @Test func parsesArraysStringsAndWrappedLists() {
        let raw: JSONValue = [["id": "1", "content": "Read", "status": "completed"], ["id": "", "content": "x", "status": "pending"],
                              ["id": "2", "content": "Write", "status": "bogus"], ["id": "3", "content": "Sub", "status": "pending", "parent": "3"]]
        let parsed = TodoRules.parseTodos(raw)
        #expect(parsed?.map(\.id) == ["1", "3"])
        #expect(parsed?[1].parent == nil)
        #expect(TodoRules.parseTodos(.string(#"{"todos":[{"id":"a","content":"A","status":"in_progress"}]}"#))?.first?.status == .inProgress)
        #expect(TodoRules.parseTodos(.number(3)) == nil)
    }

    @Test func treeOrderPutsParentsFirstAndKeepsCycles() {
        let items = [TodoItem(id: "c", content: "C", status: .pending, parent: "a"), TodoItem(id: "a", content: "A", status: .pending),
                     TodoItem(id: "x", content: "X", status: .pending, parent: "missing"),
                     TodoItem(id: "p", content: "P", status: .pending, parent: "q"), TodoItem(id: "q", content: "Q", status: .pending, parent: "p")]
        let tree = TodoRules.tree(items)
        #expect(tree.map(\.item.id) == ["a", "c", "x", "p", "q"])
        #expect(tree.map(\.depth) == [0, 1, 0, 0, 0])
    }

    @Test func revisionWatermarkAndLinger() {
        var s = TodoState()
        let active = [TodoItem(id: "1", content: "A", status: .inProgress), TodoItem(id: "2", content: "B", status: .pending)]
        let first = s.set(active, revision: 1, now: 0)
        #expect(first)
        #expect(s.live?.count == 2 && s.dropAt == nil)
        let done = active.map { var t = $0; t.status = .completed; return t }
        s.set(done, revision: 3, now: 10)
        #expect(s.dropAt == 14)
        let older = s.set(active, revision: 2, now: 11)          // older revision ignored
        #expect(!older)
        let early = s.expire(now: 13)
        #expect(!early)
        let due = s.expire(now: 14)
        #expect(due)
        #expect(s.live == nil && s.retained.count == 2)
    }

    @Test func mergePatchUpdatesAndAppends() {
        let current = [TodoItem(id: "1", content: "A", status: .pending)]
        let payload: JSONValue = ["args": ["merge": true, "todos": [["id": "1", "status": "completed"], ["id": "2", "status": "pending"]]]]
        let next = TodoRules.nextTodos(current: current, payload: payload)
        #expect(next == [TodoItem(id: "1", content: "A", status: .completed), TodoItem(id: "2", content: "(no description)", status: .pending)])
    }

    @Test func resumeRunningVersusIdle() {
        let active: JSONValue = ["todos": [["id": "1", "content": "A", "status": "in_progress"], ["id": "2", "content": "B", "status": "pending"]], "revision": 5]
        var idle = TodoState()
        idle.restore(active, running: false, now: 0)
        #expect(idle.live == nil && idle.retained.count == 2)
        var running = TodoState()
        running.restore(active, running: true, now: 0)
        #expect(running.live?.count == 2)
        var empty = TodoState()
        let applied = empty.restore(["todos": [], "revision": 0], running: false, now: 0)
        #expect(!applied)
    }

    /// Verify round 2: opening an idle chat whose last list finished shows the folded Previous tasks chip at once (no
    /// opened live card that folds 4 s later); a finished list already on screen keeps its linger.
    @Test func resumeIdleFinishedGoesStraightToPrevious() {
        let finished: JSONValue = ["todos": [["id": "1", "content": "A", "status": "completed"], ["id": "2", "content": "B", "status": "completed"]], "revision": 7]
        var opened = TodoState()
        let applied = opened.restore(finished, running: false, now: 100)
        #expect(applied)
        #expect(opened.live == nil && opened.retained.count == 2 && opened.dropAt == nil)
        var onScreen = TodoState()
        onScreen.set([TodoItem(id: "1", content: "A", status: .completed), TodoItem(id: "2", content: "B", status: .inProgress)], revision: 6, now: 90)
        onScreen.restore(finished, running: false, now: 100)
        #expect(onScreen.live?.count == 2 && onScreen.dropAt == 100 + TodoRules.finishedLinger)
    }

    @Test func turnEndDropsAnActiveListAndStopClearsAll() {
        var s = TodoState()
        s.set([TodoItem(id: "1", content: "A", status: .pending)], revision: 1, now: 0)
        let dropped = s.dropActive()
        #expect(dropped)
        #expect(s.live == nil && s.retained.count == 1)
        s.clear()
        #expect(s == TodoState())
        #expect(TodoRules.chipWords([TodoItem(id: "1", content: "A", status: .completed), TodoItem(id: "2", content: "B", status: .cancelled)],
                                    previous: false) == "Tasks 1/2")
    }
}

@Suite("Activity · goal snapshot")
struct ControlRulesTests {
    nonisolated static let goal: JSONValue = ["title": "Ship 2.4", "status": "active", "turns_used": 3, "max_turns": 20,
                                  "contract": ["outcome": "Notes published", "verification": "", "constraints": "", "boundaries": "", "stop_when": ""],
                                  "subgoals": ["Draft notes"], "gates": [], "last_verdict": "continue", "last_reason": "Notes drafted"]

    nonisolated static func snapshot(_ goal: JSONValue) -> JSONValue {
        ["goal": goal, "loop": nil, "heartbeat": nil, "revision": "r1", "updated_at": 1791633600.0]
    }

    @Test func parsesAValidSnapshotAndItsWords() throws {
        let s = try #require(ControlRules.parseSnapshot(Self.snapshot(Self.goal)))
        let g = try #require(s.goal)
        #expect(ControlRules.chipWords(g) == "Goal active · Turn 3/20")
        #expect(ControlRules.reason(g) == "Notes drafted")
        #expect(ControlRules.hasDetails(g))
    }

    @Test func aMissingContractKeyDropsTheWholeSnapshot() {
        var goal = Self.goal.object!
        goal["contract"] = ["outcome": "x"]
        #expect(ControlRules.parseSnapshot(Self.snapshot(.object(goal))) == nil)
        var extra = Self.goal.object!
        extra["surprise"] = 1
        #expect(ControlRules.parseSnapshot(Self.snapshot(.object(extra))) == nil)
    }

    @Test func labelsForEveryState() {
        var g = ControlRules.parseGoal(Self.goal)!
        g.status = .done; g.turnsUsed = 5
        #expect(ControlRules.chipWords(g) == "Goal done · 5 turns")
        g.status = .paused; g.turnsUsed = 3; g.maxTurns = 0
        #expect(ControlRules.chipWords(g) == "Goal paused · Turn 3")
        g.lastVerdict = .blocked; g.maxTurns = 20; g.turnsUsed = 14
        #expect(ControlRules.chipWords(g) == "Goal blocked · Turn 14/20")
        g.lastVerdict = nil; g.status = .active; g.waitBarrier = .session(target: "s1", reason: "child")
        #expect(ControlRules.chipWords(g).hasPrefix("Goal waiting"))
        #expect(ControlRules.reason(g) == "Wait condition: child")
    }
}

@Suite("Activity · delegate rows (delegate-model.test.ts)")
struct DelegateModelTests {
    func sub(_ id: String, goal: String, status: SubagentStatus = .running, index: Int = 0, model: String? = nil,
             stream: [String] = []) -> SubagentProgress {
        SubagentProgress(id: id, goal: goal, model: model, status: status, taskCount: 1, taskIndex: index, startedAt: 0, updatedAt: 0,
                         stream: stream.map { SubagentStreamEntry(at: 0, isError: false, kind: .tool, text: $0) })
    }

    @Test func readsGoalsAndResults() {
        #expect(ToolCards.delegateGoals(["tasks": [["goal": "A"], ["goal": "B"]]]) == ["A", "B"])
        #expect(ToolCards.delegateGoals(.string(#"{"goal":"Serialized"}"#)) == ["Serialized"])
        let args: [String: JSONValue] = ["tasks": [["goal": "A"], ["goal": "B"], ["goal": "C"], ["goal": "D"]]]
        let card = ToolCards.card(name: "delegate_task", args: args, result: ["results": [["status": "ok", "summary": "done"], ["status": "timeout"],
                                                                                         ["status": "error"], ["status": "failure"]]])
        let rows = ToolCards.rows(goals: ToolCards.delegateGoals(.object(args)), card: card, hasResult: true, toolCallId: "c")
        #expect(rows.map(\.status) == [.completed, .failed, .failed, .failed])
        let running = ToolCards.rows(goals: ["A", "B"], card: nil, hasResult: false, toolCallId: "c")
        #expect(running.map(\.status) == [.running, .running])
        let parked = ToolCards.card(name: "delegate_task", args: [:], result: ["status": "dispatched", "goals": ["A", "B"]])
        #expect(ToolCards.rows(goals: [], card: parked, hasResult: true, toolCallId: "c").map(\.goal) == ["A", "B"])
        #expect(ToolCards.rows(goals: [], card: parked, hasResult: true, toolCallId: "c").map(\.status) == [.dispatched, .dispatched])
    }

    @Test func overlayByIdThenGoalThenOrder() {
        let rows = ToolCards.rows(goals: ["A", "B"], card: nil, hasResult: false, toolCallId: "call-7")
        let merged = ToolCards.merge(rows, live: [sub("delegate-tool:call-7:1", goal: "B", status: .completed),
                                                  sub("delegate-tool:call-7:0", goal: "A", model: "gpt-5")], toolCallId: "call-7")
        #expect(merged.map(\.status) == [.running, .completed])
        #expect(merged[0].model == "gpt-5")
        let one = ToolCards.rows(goals: ["Research Cursor"], card: nil, hasResult: false, toolCallId: "call-1")
        let byGoal = ToolCards.merge(one, live: [sub("x", goal: "research cursor ", stream: ["Read File(\"a.ts\")", "comparing"])], toolCallId: "call-1")
        #expect(byGoal[0].activity == ["Read File(\"a.ts\")", "comparing"])
        let other = ToolCards.rows(goals: ["C"], card: nil, hasResult: false, toolCallId: "call-2")
        #expect(ToolCards.merge(other, live: [sub("a", goal: "A"), sub("b", goal: "B")], toolCallId: "call-2")[0].model == nil)
        let shape = ToolCards.rows(goals: ["A", "B"], card: nil, hasResult: false, toolCallId: "call-3")
        let ordered = ToolCards.merge(shape, live: [sub("x", goal: "renamed A", index: 0, model: "m0"), sub("y", goal: "renamed B", index: 1, model: "m1")],
                                      toolCallId: "call-3")
        #expect(ordered.map(\.model) == ["m0", "m1"])
    }

    @Test func durationWordsAndImageGeometry() {
        #expect(ToolCards.formatDurationSeconds(0.4) == "400ms")
        #expect(ToolCards.formatDurationSeconds(4.2) == "4.2s")
        #expect(ToolCards.formatDurationSeconds(42) == "42s")
        #expect(ToolCards.formatDurationSeconds(125) == "2m 5s")
        #expect(ToolCards.formatDurationSeconds(3600) == "1h")
        let image = ToolCards.card(name: "image_generate", args: ["aspect_ratio": "square"],
                                   result: ["success": true, "host_image": "/fixture/x.png", "pixel_size": "1024x768"])
        #expect(image == .image(path: "/fixture/x.png", aspect: "square", pixelWidth: 1024, pixelHeight: 768))
        #expect(ToolCards.card(name: "image_generate", args: [:], result: ["success": false, "image": "/x.png"]) == nil)
        #expect(ToolCards.imageRatio(aspect: "portrait", pixelWidth: nil, pixelHeight: nil) == 9.0 / 16.0)
        // The cache form round-trips.
        #expect(ToolCard(json: image!.json) == image)
    }
}

@Suite("Activity · diffs, waits, steps")
struct StepRulesTests {
    @Test func diffCleanupYieldsOneRemovedAndOneAddedLine() {
        let raw = "\u{1B}[31m┊ review diff\na/src/app.py → b/src/app.py\n@@ -1 +1 @@\n-print('before')\n+print('after')"
        let lines = StepRules.diffLines(raw)
        #expect(lines == [.init(kind: .removed, text: "print('before')"), .init(kind: .added, text: "print('after')")])
        let git = "diff --git a/x b/x\nindex 1..2\n--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n keep\n-old\n+new\n@@ -9 +9 @@\n-z\n+y"
        #expect(StepRules.diffLines(git).map(\.text) == ["keep", "old", "new", "", "z", "y"])
    }

    @Test func providerWaitFilter() {
        #expect(ProviderWait.text("⏳ waiting on provider…") == "⏳ waiting on provider…")
        #expect(ProviderWait.text("⚠ Rate limited — retrying in 4s") == "⚠ Rate limited — retrying in 4s")
        #expect(ProviderWait.text("(｡•́︿•̀｡) pondering…") == "")
        #expect(ProviderWait.fallbackNotice(kind: "fallback", text: "⚠ Model fallback: switched to fixture-2") != nil)
        #expect(ProviderWait.fallbackNotice(kind: "status", text: "Switched to fallback provider") != nil)
        #expect(ProviderWait.fallbackNotice(kind: "status", text: "Compacting") == nil)
        let names: (String) -> String = { ["claude-opus-5-5": "Opus 5.5", "gpt-6.1-sol": "GPT-6.1-sol"][$0] ?? $0 }
        #expect(ProviderWait.plainNotice("⚠️ Model fallback: claude-opus-5-5[1m] via claude-subscription-directsdk-experimental unavailable (rate limit); using gpt-6.1-sol via openai-codex. Primary retry eligible in ~60 s; recovery is not guaranteed.", displayName: names)
                == "Opus 5.5 hit a usage limit, so GPT-6.1-sol is answering for now.")
        #expect(ProviderWait.plainNotice("Model fallback: a via p unavailable (overloaded); using b via q.", displayName: names) == "a is busy, so b is answering for now.")
        let providers: (String) -> String = { ["anthropic": "Anthropic", "openai-codex": "OpenAI Codex"][$0] ?? $0 }
        #expect(ProviderWait.plainNotice("⚠️ Provider fallback: anthropic unavailable; using openai-codex for this response.", displayName: names, providerName: providers)
                == "Anthropic isn't available, so OpenAI Codex is answering for now.")
        #expect(ProviderWait.plainNotice("⚠️ Provider fallback: anthropic/claude-opus-5-5 unavailable; using openai-codex/gpt-6.1-sol for this response.", displayName: names, providerName: providers)
                == "Opus 5.5 isn't available, so GPT-6.1-sol is answering for now.")
        #expect(ProviderWait.plainNotice("⚠️ Provider fallback: primary unavailable; using fallback for this response.", displayName: names, providerName: providers)
                == "Your usual model isn't available, so another model is answering for now.")
        #expect(ProviderWait.plainNotice("⚠️ Model fallback: claude-opus-5-5 via anthropic unavailable (billing or quota exhausted); using gpt-6.1-sol via openai-codex.", displayName: names)
                == "Opus 5.5 hit a usage limit, so GPT-6.1-sol is answering for now.")
        #expect(ProviderWait.plainNotice("⚠️ Model fallback: claude-opus-5-5 via anthropic unavailable (authentication failed); using gpt-6.1-sol via openai-codex.", displayName: names)
                == "Opus 5.5 couldn't sign in, so GPT-6.1-sol is answering for now.")
        #expect(ProviderWait.plainNotice("⚠️ Model fallback: claude-opus-5-5 via anthropic unavailable (request timeout); using gpt-6.1-sol via openai-codex. Primary retry eligible in ~0 s; recovery is not guaranteed.", displayName: names)
                == "Opus 5.5 isn't responding, so GPT-6.1-sol is answering for now.")
        #expect(ProviderWait.plainNotice("⚠️ Model fallback: openrouter/anthropic/claude-opus-5-5 via openrouter unavailable (model not found); using gpt-6.1-sol via custom:api.example.com.", displayName: names)
                == "Opus 5.5 isn't available, so GPT-6.1-sol is answering for now.")
        #expect(ProviderWait.plainNotice("Primary model restored: claude-opus-5-5.", displayName: names) == "Back to Opus 5.5.")
        #expect(ProviderWait.plainNotice("⚠ Model fallback: switched to fixture-2") == "Model fallback: switched to fixture-2")
    }

    @Test func stepsState() {
        let call = ToolCall(id: "1", name: "terminal", title: "t", argsText: nil, summary: nil, state: .done, durationSeconds: nil)
        var failed = call; failed.state = .failed
        #expect(StepRules.state([.tool(call), .text("Done.")], working: true) == .working)
        #expect(StepRules.state([.tool(call), .text("Done.")], working: false) == .done)
        #expect(StepRules.state([.tool(failed)], working: false) == .failed)
        #expect(StepRules.state([.tool(failed), .text("  ")], working: false) == .failed)
        #expect(StepRules.state([.tool(failed), .text("The build failed, so I retried.")], working: false) == .done)
        #expect(StepRules.state([.text("Trying."), .tool(failed)], working: false) == .failed)
    }

    @Test func pages() {
        let text = String(repeating: "x", count: 25_000)
        #expect(StepRules.pages(text) == 2)
        #expect(StepRules.page(text, 1).count == 5_000)
    }

    @Test func displayFlags() {
        #expect(!DisplayFlags(config: ["display": ["show_reasoning": false]]).showReasoning)
        #expect(!DisplayFlags(config: ["display": ["show_reasoning": "false"]]).showReasoning)
        #expect(DisplayFlags(config: ["display": [:]]).showReasoning)
        #expect(DisplayFlags(config: ["display": ["tool_progress": "OFF"]]).toolProgressOff)
        #expect(!DisplayFlags(config: ["display": ["tool_progress": "all"]]).toolProgressOff)
    }
}
