// Tool Call Style › One Line, a reply's words as one bubble, and Fewer Timestamps: how a busy bot thread is drawn
// quieter. Drawing only: the messages are the ones Hermes sent.

import Foundation
import Testing
@testable import HermesHQNative

@Suite("Activity · one line")
struct OneLineRowsTests {
    func call(_ id: String, _ name: String, _ args: String = "{}", state: ToolCall.State = .done, seconds: Double? = nil) -> ToolCall {
        ToolCall(id: id, name: name, title: name, argsText: args, summary: nil, state: state, durationSeconds: seconds)
    }

    func input(_ messages: [ChatMessage], running: Bool = false, fewerTimes: Bool = false,
               _ configure: (inout ActivityRowsInput) -> Void = { _ in }) -> ChatRowBuilder.Input {
        var a = ActivityRowsInput()
        configure(&a)
        var i = ChatRowBuilder.Input(messages: messages, isRunning: running, botName: "Hermes", expanded: [], scope: "t", activity: a)
        i.fewerTimes = fewerTimes
        return i
    }

    func reply(_ parts: [ChatPart], streaming: Bool = false) -> [ChatMessage] {
        var a = ChatMessage(id: "a", role: .assistant, parts: parts, timestamp: Date(), rowId: 2)
        a.isStreaming = streaming
        return [ChatMessage(id: "u", role: .user, parts: [.text("go")], timestamp: Date(), rowId: 1), a]
    }

    /// Text, steps, more text: a reply the way Hermes sends a busy one.
    var split: [ChatPart] {
        [.reasoning("plan"), .text("Checking."), .tool(call("t1", "terminal", #"{"command":"npm test"}"#, seconds: 40.6)),
         .tool(call("t2", "read_file", #"{"path":"/a/README.md"}"#, seconds: 1.2)), .text("All good.")]
    }

    func line(_ rows: [ChatRow]) -> (ToolRunRow, OneLineRow)? {
        for row in rows { if case .toolRun(let t) = row.kind, let l = t.line { return (t, l) } }
        return nil
    }

    func bubbles(_ rows: [ChatRow]) -> [String] {
        rows.compactMap { if case .bubble(let b) = $0.kind, !b.mine { return b.text } else { return nil } }
    }

    @Test func oneLineFoldsAReplyIntoOneLineAboveItsWords() {
        let rows = ChatRowBuilder.build(input(reply(split)) { $0.style = .line })
        guard let (run, l) = line(rows) else { Issue.record("no line"); return }
        #expect(l.title == "Worked for 42s · 2 steps")
        #expect(l.glyph == .worked)
        #expect(l.thought == "plan")
        #expect(run.tools.map(\.id) == ["t1", "t2"])
        #expect(!run.live)
        // The note before the steps and the answer after them are two messages (kwojt 2026-11-14).
        #expect(bubbles(rows) == ["Checking.", "All good."])
        // The line sits above the reply's words.
        let lineAt = rows.firstIndex { $0.id == "a|line" }, bubbleAt = rows.firstIndex { $0.id == "a|b1" }
        #expect(lineAt != nil && bubbleAt != nil && lineAt! < bubbleAt!)
        #expect(!rows.contains { if case .thought = $0.kind { return true } else { return false } })
    }

    /// [updates] Subagents are said on the line ("2 helpers working", then "· 2 helpers"), not drawn as a card each.
    @Test func helpersFoldIntoTheLine() {
        func delegate(_ state: ToolCall.State, _ results: [DelegateResult]?) -> ChatPart {
            var c = call("d1", "delegate_task", #"{"tasks":[{"goal":"A"},{"goal":"B"}]}"#, state: state, seconds: 30)
            // A running call has no card yet (its rows read as running).
            if let results { c.card = .delegate(goals: ["A", "B"], results: results, dispatchedGoals: nil) }
            return .tool(c)
        }
        let done: [ChatPart] = [.tool(call("t1", "terminal", seconds: 10)), delegate(.done, [DelegateResult(status: "completed"), DelegateResult(status: "completed")]),
                                .text("Both done.")]
        let rows = ChatRowBuilder.build(input(reply(done)) { $0.style = .line })
        #expect(line(rows)?.1.title == "Worked for 40s · 2 helpers")
        #expect(line(rows)?.0.tools.map(\.id) == ["t1", "d1"])
        #expect(!rows.contains { if case .activity(.delegate) = $0.kind { return true } else { return false } })
        let live = ChatRowBuilder.build(input(reply([delegate(.running, nil)], streaming: true), running: true) { $0.style = .line })
        #expect(line(live)?.1.title == "2 helpers working")
        #expect(line(live)?.1.glyph == .subagent)
        #expect(line(live)?.0.live == true)
        // Header style keeps its cards.
        #expect(ChatRowBuilder.build(input(reply(done)) { $0.style = .header }).contains { if case .activity(.delegate) = $0.kind { return true } else { return false } })
    }

    @Test func untimedStepsSayWhatTheReplyDid() {
        let parts: [ChatPart] = [.tool(call("t1", "terminal", #"{"command":"npm test"}"#)), .text("ok")]
        let rows = ChatRowBuilder.build(input(reply(parts)) { $0.style = .line })
        #expect(line(rows)?.1.title == ChatRunSummary.summarize([call("t1", "terminal", #"{"command":"npm test"}"#)], live: false))
        // This device timed the turn: that time wins.
        var timed = input(reply(parts)) { $0.style = .line }
        timed.turnSeconds = ["a": 75]
        #expect(line(ChatRowBuilder.build(timed))?.1.title == "Worked for 1:15")
    }

    /// [toolnow] While it works, the thinking row under the line names the step ("Ivy is running npm test…"), so the
    /// line itself reads "Working" with the step's glyph.
    @Test func whileWorkingTheLineSaysWorking() {
        let running: [ChatPart] = [.reasoning("plan"), .tool(call("t1", "terminal", #"{"command":"npm test"}"#, state: .running))]
        let working = line(ChatRowBuilder.build(input(reply(running, streaming: true), running: true) { $0.style = .line }))
        #expect(working?.0.live == true)
        #expect(working?.1.title == "Working")
        let thinking = line(ChatRowBuilder.build(input(reply([.reasoning("plan")], streaming: true), running: true) { $0.style = .line }))
        #expect(thinking?.1.title == "Thinking")
        // Between steps (the last one finished, the next not started) it still reads as working.
        let between = line(ChatRowBuilder.build(input(reply([.tool(call("t1", "terminal", #"{"command":"npm test"}"#))], streaming: true),
                                                     running: true) { $0.style = .line }))
        #expect(between?.0.live == true)
        #expect(between?.1.title == "Working")
        // Writing its answer: the line has settled.
        let writing = line(ChatRowBuilder.build(input(reply(split, streaming: true), running: true) { $0.style = .line }))
        #expect(writing?.0.live == false)
        #expect(writing?.1.title == "Worked for 42s · 2 steps")
    }

    @Test func hideClearsTheLineOnceDone() {
        let rows = ChatRowBuilder.build(input(reply(split)) { $0.style = .line; $0.hideSteps = true })
        #expect(line(rows) == nil)
        #expect(bubbles(rows) == ["Checking.", "All good."])
    }

    @Test func rowsStillShowStepsBetweenTheWords() {
        let rows = ChatRowBuilder.build(input(reply(split)))
        #expect(bubbles(rows) == ["Checking.", "All good."])
        #expect(line(rows) == nil)
    }

    @Test func wordsWithNothingBetweenThemAreOneBubble() {
        let parts: [ChatPart] = [.text("One."), .tool(call("s", "todo")), .text("Two.")]
        #expect(ChatRunSummary.isSilent("todo"))
        #expect(bubbles(ChatRowBuilder.build(input(reply(parts)))) == ["One.\n\nTwo."])
        // A thought between them folds into the line (Rows draws it as its own row, which splits the words there).
        let thought: [ChatPart] = [.text("One."), .tool(call("s", "todo")), .reasoning("hmm"), .text("Two.")]
        for style in [ToolCallStyle.line, .bottom, .header] {
            #expect(bubbles(ChatRowBuilder.build(input(reply(thought)) { $0.style = style })) == ["One.\n\nTwo."], "\(style)")
        }
    }

    /// kwojt 2026-11-14 (build 980, "Basal — approver zgód"): a long turn's progress notes, each written before the bot
    /// went back to work, drew as one long bubble under the steps line. Each note is its own message, as on Telegram,
    /// stacked tight under the line: one gap, the name once, the tail and time on the last.
    @Test func progressNotesBetweenStepsAreTheirOwnBubbles() {
        let parts: [ChatPart] = [
            .text("First the key."), .tool(call("t1", "write_file", #"{"path":"/a/key.py"}"#)),
            .text("The secrets check says the key is there."), .tool(call("t2", "terminal", #"{"command":"pytest"}"#)),
            .tool(call("t3", "read_file", #"{"path":"/a/b.py"}"#)),
            .text("An important finding."), .tool(call("s", "todo")), .text("The first batch is 220 requests."),
        ]
        let notes = ["First the key.", "The secrets check says the key is there.",
                     "An important finding.\n\nThe first batch is 220 requests."]
        for style in [ToolCallStyle.line, .bottom, .header, .rows, .bubbles] {
            #expect(bubbles(ChatRowBuilder.build(input(reply(parts)) { $0.style = style })) == notes, "\(style)")
        }
        #expect(bubbles(ChatRowBuilder.build(input(reply(parts)) { $0.style = .line; $0.hideSteps = true })) == notes)
        let rows = ChatRowBuilder.build(input(reply(parts), fewerTimes: true) { $0.style = .line })
        let drawn = rows.compactMap { row -> (ChatRow, BubbleRow)? in
            if case .bubble(let b) = row.kind, !b.mine { return (row, b) } else { return nil }
        }
        #expect(drawn.map(\.1.joinsAbove) == [false, true, true])
        #expect(drawn.map(\.1.joinsBelow) == [true, true, false])
        #expect(drawn.map(\.1.tail) == [false, false, true])
        #expect(drawn.map { $0.1.time != nil } == [false, false, true])
        #expect(drawn.dropFirst().allSatisfy { $0.0.gapAbove == ChatMetrics.runGap })
        // The steps line stays one, above the first note.
        #expect(rows.filter { $0.id == "a|line" }.count == 1)
        let lineAt = rows.firstIndex { $0.id == "a|line" }, firstNote = rows.firstIndex { $0.id == drawn.first?.0.id }
        #expect(lineAt != nil && firstNote != nil && lineAt! < firstNote!)
        #expect(line(rows)?.0.tools.map(\.id) == ["t1", "t2", "t3"])
    }

    @Test func fewerTimestampsDrawsADayLineOnlyAtADateChange() {
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date().addingTimeInterval(-86_400 * 2))!
        func at(_ minutes: Double) -> Date { noon.addingTimeInterval(minutes * 60) }
        let messages = [
            ChatMessage(id: "u1", role: .user, parts: [.text("one")], timestamp: at(0), rowId: 1),
            ChatMessage(id: "a1", role: .assistant, parts: [.text("ok")], timestamp: at(1), rowId: 2),
            ChatMessage(id: "u2", role: .user, parts: [.text("two")], timestamp: at(45), rowId: 3),
            ChatMessage(id: "a2", role: .assistant, parts: [.text("ok")], timestamp: at(46), rowId: 4),
            ChatMessage(id: "u3", role: .user, parts: [.text("next day")], timestamp: at(24 * 60), rowId: 5),
        ]
        func days(_ rows: [ChatRow]) -> Int { rows.filter { if case .day = $0.kind { return true } else { return false } }.count }
        #expect(days(ChatRowBuilder.build(input(messages))) == 3)
        let fewer = ChatRowBuilder.build(input(messages, fewerTimes: true))
        #expect(days(fewer) == 2)
        // Times only under the bot's replies.
        let times = fewer.compactMap { row -> (Bool, Bool)? in
            if case .bubble(let b) = row.kind { return (b.mine, b.time != nil) } else { return nil }
        }
        #expect(times.filter { $0.0 }.allSatisfy { !$0.1 })
        #expect(times.filter { !$0.0 }.allSatisfy { $0.1 })
        // VoiceOver still reads your messages' times: each of yours carries its time to be spoken, no reply does.
        let spoken = fewer.compactMap { row -> (Bool, Date?)? in
            if case .bubble(let b) = row.kind { return (b.mine, b.spokenTime) } else { return nil }
        }
        #expect(spoken.filter { $0.0 }.map(\.1) == [at(0), at(45), at(24 * 60)])
        #expect(spoken.filter { !$0.0 }.allSatisfy { $0.1 == nil })
        let all = ChatRowBuilder.build(input(messages)).compactMap { row -> Date?? in
            if case .bubble(let b) = row.kind { return .some(b.spokenTime) } else { return nil }
        }
        #expect(all.allSatisfy { $0 == nil }, "with every time drawn, none is kept apart")
    }

    @Test func aLongRunCountsItsStepsApartFromTheTitle() {
        let three = [call("t1", "terminal", #"{"command":"npm test"}"#), call("t2", "read_file", #"{"path":"/a/README.md"}"#),
                     call("t3", "terminal", #"{"command":"ls"}"#, state: .running)]
        // Working: "Working" (the thinking row names the step), the count at the trailing end.
        let working = line(ChatRowBuilder.build(input(reply(three.map { .tool($0) }, streaming: true), running: true) { $0.style = .line }))
        #expect(working?.1.title == "Working")
        #expect(working?.1.meta == "3 steps")
        // History with no time known: the summary stays the title (it may be cut short); the count still shows.
        let done = three.map { var c = $0; c.state = .done; return c }
        let history = line(ChatRowBuilder.build(input(reply(done.map { .tool($0) } + [.text("ok")])) { $0.style = .line }))
        #expect(history?.1.title == ChatRunSummary.summarize(done, live: false))
        #expect(history?.1.meta == "3 steps")
        // A timed run says it in the title, so no meta; nor does a run of one.
        #expect(line(ChatRowBuilder.build(input(reply(split)) { $0.style = .line }))?.1.meta == nil)
        let one = [ChatPart.tool(call("t1", "terminal", #"{"command":"npm test"}"#)), .text("ok")]
        #expect(line(ChatRowBuilder.build(input(reply(one)) { $0.style = .line }))?.1.meta == nil)
    }

    @Test func oneLineIsAStyleInSettings() {
        #expect(ToolCallStyle.allCases.map(\.title) == ["Rows", "One Line", "At the Bottom", "Bubbles", "In Header"])
    }

    /// At the Bottom (owner, 2026-10-28): no line above the running reply, the thinking row names the step; once the turn
    /// is done the reply's line is One Line's.
    @Test func atTheBottomHoldsTheLineWhileTheTurnRuns() {
        let steps: [ChatPart] = [.tool(call("t1", "terminal", #"{"command":"npm test"}"#)),
                                 .tool(call("t2", "read_file", #"{"path":"/a/README.md"}"#, state: .running))]
        let running = ChatRowBuilder.build(input(reply(steps, streaming: true), running: true) { $0.style = .bottom })
        #expect(line(running) == nil)
        let waiting = running.compactMap { row -> WaitingRow? in if case .waiting(let w) = row.kind { return w } else { return nil } }
        #expect(waiting.count == 1 && waiting[0].label == "Hermes is reading README.md…")
        // Words between steps: still no line above them while the turn runs.
        let writing = ChatRowBuilder.build(input(reply(steps + [.text("Checking.")], streaming: true), running: true) { $0.style = .bottom })
        #expect(line(writing) == nil)
        // Done: the line comes, as One Line draws it.
        let done = steps.map { part -> ChatPart in if case .tool(var c) = part { c.state = .done; return .tool(c) } else { return part } }
        let finished = line(ChatRowBuilder.build(input(reply(done + [.text("All good.")])) { $0.style = .bottom }))
        let oneLine = line(ChatRowBuilder.build(input(reply(done + [.text("All good.")])) { $0.style = .line }))
        #expect(finished != nil && finished?.1.title == oneLine?.1.title)
        // One Line keeps its live line.
        #expect(line(ChatRowBuilder.build(input(reply(steps, streaming: true), running: true) { $0.style = .line })) != nil)
    }

    @Test func oneLineAndFewerTimestampsAreTheDefaults() {
        let d = UserDefaults.standard
        let keys = [ToolCallSettings.styleKey, ToolCallSettings.fewerTimestampsKey]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }
        keys.forEach(d.removeObject(forKey:))
        #expect(ToolCallSettings.style == .bottom)          // At the Bottom since 2026-10-28
        #expect(ToolCallSettings.fewerTimestamps)
        // Rows and "off" are remembered once chosen.
        ToolCallSettings.style = .rows
        ToolCallSettings.fewerTimestamps = false
        #expect(ToolCallSettings.style == .rows && !ToolCallSettings.fewerTimestamps)
        ToolCallSettings.style = .line
        #expect(ToolCallSettings.style == .line)            // One Line is remembered once chosen
        ToolCallSettings.style = .bottom
        ToolCallSettings.fewerTimestamps = true
        #expect(d.object(forKey: ToolCallSettings.styleKey) == nil && d.object(forKey: ToolCallSettings.fewerTimestampsKey) == nil)
    }
}
