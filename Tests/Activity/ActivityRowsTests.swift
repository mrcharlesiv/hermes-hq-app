// Row building for the activity stream (docs/spec/1x-activity.md §9–§11): styles, Hide, reasoning words, cards, and the
// diff's handling of rows that change order (a turn-end read can fold a reply's parts in stored order).

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Activity · rows")
struct ActivityRowsTests {
    func call(_ id: String, _ name: String, _ args: String = "{}", state: ToolCall.State = .done, card: ToolCard? = nil) -> ToolCall {
        var c = ToolCall(id: id, name: name, title: name, argsText: args, summary: nil, state: state, durationSeconds: nil)
        c.card = card
        return c
    }

    func input(_ messages: [ChatMessage], running: Bool = false, _ configure: (inout ActivityRowsInput) -> Void = { _ in }) -> ChatRowBuilder.Input {
        var a = ActivityRowsInput()
        configure(&a)
        return ChatRowBuilder.Input(messages: messages, isRunning: running, botName: "Hermes", expanded: [], scope: "t", activity: a)
    }

    var turn: [ChatMessage] {
        [ChatMessage(id: "u", role: .user, parts: [.text("go")], timestamp: Date(), rowId: 1),
         ChatMessage(id: "a", role: .assistant, parts: [.reasoning("plan"), .tool(call("t1", "terminal", #"{"command":"npm test"}"#)),
                                                       .tool(call("t2", "read_file", #"{"path":"/a/README.md"}"#)), .text("Done.")],
                     timestamp: Date(), rowId: 2)]
    }

    func kinds(_ rows: [ChatRow]) -> [String] {
        rows.map { row in
            switch row.kind {
            case .bubble: return "bubble"
            case .toolRun: return "run"
            case .thought(let t): return "thought:\(t.title)"
            case .activity(.toolBubble(let t)): return "tools:\(t.lines.count)"
            case .activity(.delegate): return "delegate"
            case .activity(.image): return "image"
            case .actions: return "actions"
            case .day: return "day"
            default: return "other"
            }
        }.filter { $0 != "day" }
    }

    @Test func rowsKeepTheM1Look() {
        #expect(kinds(ChatRowBuilder.build(input(turn))) == ["bubble", "thought:Thought", "run", "bubble"])
    }

    @Test func bubblesTurnARunIntoOneToolBubble() {
        let rows = ChatRowBuilder.build(input(turn) { $0.style = .bubbles })
        #expect(kinds(rows) == ["bubble", "thought:Thought", "tools:2", "bubble"])
        guard case .activity(.toolBubble(let t))? = rows.first(where: { $0.id.contains("|tb") })?.kind else { Issue.record("no bubble"); return }
        #expect(t.lines[0].line.code == "npm test" && t.lines[0].language == "Shell")
        #expect(t.joinsBelow)
    }

    @Test func bubblesFoldEarlierLinesPastEight() {
        let calls = (0..<10).map { ChatPart.tool(call("c\($0)", "terminal", #"{"command":"ls \#($0)"}"#)) }
        let messages = [turn[0], ChatMessage(id: "a", role: .assistant, parts: calls, timestamp: Date(), rowId: 2)]
        let rows = ChatRowBuilder.build(input(messages) { $0.style = .bubbles })
        guard case .activity(.toolBubble(let t))? = rows.first(where: { $0.id.contains("|tb") })?.kind else { Issue.record("no bubble"); return }
        #expect(t.earlier == 3 && t.lines.count == 7)
    }

    @Test func inHeaderDrawsNoStepsButKeepsCards() {
        var parts = turn[1].parts
        parts.insert(.tool(call("d1", "delegate_task", #"{"goal":"A"}"#, card: .delegate(goals: ["A"], results: [DelegateResult(status: "completed")], dispatchedGoals: nil))), at: 2)
        let messages = [turn[0], ChatMessage(id: "a", role: .assistant, parts: parts, timestamp: Date(), rowId: 2)]
        #expect(kinds(ChatRowBuilder.build(input(messages) { $0.style = .header })) == ["bubble", "delegate", "bubble"])
    }

    @Test func hideFoldsADoneReplyButKeepsAFailedOne() {
        #expect(kinds(ChatRowBuilder.build(input(turn) { $0.hideSteps = true })) == ["bubble", "bubble"])
        // Still working: steps show.
        var live = turn
        live[1].isStreaming = true
        #expect(kinds(ChatRowBuilder.build(input(live, running: true) { $0.hideSteps = true })).contains("run"))
        // Show Steps brings them back; a fold in progress keeps them.
        #expect(kinds(ChatRowBuilder.build(input(turn) { $0.hideSteps = true; $0.revealed = ["a"] })).contains("run"))
        #expect(kinds(ChatRowBuilder.build(input(turn) { $0.hideSteps = true; $0.folding = ["a"] })).contains("run"))
        // A failed last call with no prose after it keeps its steps.
        let failed = [turn[0], ChatMessage(id: "a", role: .assistant, parts: [.text("Trying."), .tool(call("t1", "terminal", state: .failed))],
                                           timestamp: Date(), rowId: 2)]
        #expect(kinds(ChatRowBuilder.build(input(failed) { $0.hideSteps = true })).contains("run"))
    }

    @Test func reasoningWordsAndTheOffFlag() {
        let titles = { (seconds: Double?) -> [String] in
            kinds(ChatRowBuilder.build(input(self.turn) { if let seconds { $0.reasoningSeconds = ["a": [0: seconds]] } }))
                .filter { $0.hasPrefix("thought") }
        }
        #expect(titles(7) == ["thought:Thought for 7s"])
        #expect(titles(0) == ["thought:Thought briefly"])
        #expect(titles(65) == ["thought:Thought for 1:05"])
        #expect(titles(nil) == ["thought:Thought"])
        #expect(!kinds(ChatRowBuilder.build(input(turn) { $0.showReasoning = false })).contains { $0.hasPrefix("thought") })
    }

    @Test func toolProgressOffKeepsFileEditsAndFailures() {
        let parts: [ChatPart] = [.tool(call("t1", "terminal")), .tool(call("p1", "patch", #"{"path":"a.py"}"#)),
                                 .tool(call("t2", "read_file", state: .failed)), .text("ok")]
        let messages = [turn[0], ChatMessage(id: "a", role: .assistant, parts: parts, timestamp: Date(), rowId: 2)]
        let rows = ChatRowBuilder.build(input(messages) { $0.toolProgressOff = true })
        #expect(rows.filter { if case .toolRun = $0.kind { return true } else { return false } }.count == 2)
    }

    @Test func clarifyStaysARowInEveryStyle() {
        let parts: [ChatPart] = [.tool(call("t1", "terminal")), .tool(call("q1", "clarify")), .tool(call("t2", "terminal")), .text("ok")]
        let messages = [turn[0], ChatMessage(id: "a", role: .assistant, parts: parts, timestamp: Date(), rowId: 2)]
        for style in ToolCallStyle.allCases {
            let rows = ChatRowBuilder.build(input(messages) { $0.style = style; $0.hideSteps = style != .header })
            #expect(rows.contains { row in if case .toolRun(let t) = row.kind { return t.tools.contains { $0.name == "clarify" } } else { return false } })
        }
        #expect(kinds(ChatRowBuilder.build(input(messages))) == ["bubble", "run", "run", "run", "bubble"])
    }

    /// UX study 2026-10-21 #111: every style says what it does in one line of its own.
    @Test func everyStyleHasItsOwnLine() {
        let details = ToolCallStyle.allCases.map(\.detail)
        #expect(details.allSatisfy { !$0.isEmpty && !$0.contains("\n") })
        #expect(Set(details).count == ToolCallStyle.allCases.count)
        #expect(ToolCallStyle.line.detail.contains("Worked for 42s\u{00A0}· 5\u{00A0}steps"))
    }

    @Test func waitingCapsuleShowsAnExplainedWait() {
        let messages = [turn[0]]
        let rows = ChatRowBuilder.build(input(messages, running: true) { $0.providerWait = "⏳ waiting on provider" })
        guard case .waiting(let w)? = rows.last?.kind else { Issue.record("no capsule"); return }
        #expect(w.label == "⏳ waiting on provider")
    }

    @Test func diffTakesReorderedRowsOutAndBackIn() {
        func row(_ id: String) -> ChatRow { ChatRow(id: id, messageId: "m", scope: "d", fingerprint: 0, kind: .notice(id), gapAbove: 6, variant: 0) }
        let old = ["a", "b", "c", "d"].map(row)
        let new = ["a", "c", "b", "d"].map(row)
        let d = ChatRowDiff.make(old: old, new: new[...])
        var ids = old.map(\.id)
        for i in d.deletes.sorted(by: >) { ids.remove(at: i) }
        for i in d.inserts.sorted() { ids.insert(new[i].id, at: i) }
        #expect(ids == new.map(\.id))
        #expect(d.changed.isEmpty)
    }
}
