// [transcript] F10: the "N files changed" card under a settled reply, and a landed edit's inline diff preview
// (docs/spec/3x-transcript.md §12, n20 F10). Rows only: the messages and diffs are as Hermes sends them.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@Suite struct ChangedFilesCardTests {
    func edit(_ id: String, _ path: String, _ name: String = "patch", state: ToolCall.State = .done) -> ToolCall {
        ToolCall(id: id, name: name, title: "Edit \(path)", argsText: #"{"path":"\#(path)"}"#, summary: nil, state: state,
                 durationSeconds: 1)
    }

    func diff(_ added: Int, _ removed: Int = 0) -> String {
        "--- a/x\n+++ b/x\n@@ -1 +1 @@\n" + (0..<removed).map { "-old \($0)\n" }.joined() + (0..<added).map { "+new \($0)\n" }.joined()
    }

    func input(_ parts: [ChatPart], diffs: [String: String], style: ToolCallStyle = .line, streaming: Bool = false,
              hide: Bool = false, folding: Set<String> = []) -> ChatRowBuilder.Input {
        var a = ChatMessage(id: "a", role: .assistant, parts: parts, timestamp: Date(), rowId: 2)
        a.isStreaming = streaming
        let messages = [ChatMessage(id: "u", role: .user, parts: [.text("fix it")], timestamp: Date(), rowId: 1), a]
        var activity = ActivityRowsInput()
        activity.style = style
        activity.hideSteps = hide
        activity.folding = folding
        var i = ChatRowBuilder.Input(messages: messages, isRunning: streaming, botName: "Hermes", expanded: [], scope: "t",
                                     activity: activity)
        i.diffs = diffs
        return i
    }

    func card(_ rows: [ChatRow]) -> ChangedFilesRow? {
        for row in rows { if case .activity(.changedFiles(let c)) = row.kind { return c } }
        return nil
    }

    func previews(_ rows: [ChatRow]) -> [DiffPreviewRow] {
        rows.compactMap { if case .activity(.diffPreview(let d)) = $0.kind { return d } else { return nil } }
    }

    var threeFiles: ([ChatPart], [String: String]) {
        ([.tool(edit("e1", "src/app.py")), .tool(edit("e2", "README.md", "write_file")), .tool(edit("e3", "src/app.py")),
          .tool(edit("e4", "broken.py", state: .failed)), .text("Done.")],
         ["e1": diff(2, 1), "e2": diff(5), "e3": diff(1, 3), "e4": diff(9)])
    }

    @Test func aSettledReplyCarriesTheCardAsTheTurnsLastRow() throws {
        let (parts, diffs) = threeFiles
        let rows = ChatRowBuilder.build(input(parts, diffs: diffs))
        let c = try #require(card(rows))
        #expect(c.files.map(\.name) == ["app.py", "README.md"], "a file edited twice is one row; a failed edit is none")
        #expect(c.files[0].added == 3 && c.files[0].removed == 4)
        #expect(c.files[0].edits == 2 && c.files[1].edits == 1, "the card says the sum is two edits' worth")
        let cardAt = try #require(rows.firstIndex { $0.id == "a|files" })
        #expect(cardAt == rows.count - 1, "the card is the reply's own last word")
        #expect(previews(rows).isEmpty, "One Line leaves the changes to the card")
    }

    @Test func noCardWhileTheReplyRunsOrWithoutLandedEdits() {
        let (parts, diffs) = threeFiles
        #expect(card(ChatRowBuilder.build(input(parts, diffs: diffs, streaming: true))) == nil)
        #expect(card(ChatRowBuilder.build(input(parts, diffs: [:]))) == nil)
        let failedOnly: [ChatPart] = [.tool(edit("e4", "broken.py", state: .failed)), .text("Couldn’t.")]
        #expect(card(ChatRowBuilder.build(input(failedOnly, diffs: ["e4": diff(3)]))) == nil)
    }

    /// The `inline_diff` exactly as a Hermes gateway sends it (agent/display.py): a "┊ review diff" line, an
    /// "a/… → b/…" header, and every line wrapped in 24-bit colour codes. Counted raw, that was "+0" (owner 2026-11-10).
    func hermesDiff(_ path: String, added: [String], removed: [String] = []) -> String {
        let e = "\u{1B}"
        let fg = "\(e)[38;2;150;150;150m", bg = "\(e)[48;2;20;60;20m", reset = "\(e)[0m"
        var lines = ["  ┊ review diff", "\(fg)a/\(path) → b/\(path)\(reset)", "\(fg)@@ -1,\(removed.count) +1,\(added.count) @@\(reset)"]
        lines += removed.map { "\(fg)\(bg)-\($0)\(reset)" }
        lines += added.map { "\(fg)\(bg)+\($0)\(reset)" }
        return lines.joined(separator: "\n")
    }

    @Test func aColouredHermesDiffCountsItsLines() throws {
        let raw = hermesDiff("meal-plan.md", added: ["# Meals", "- Tacos", "- Curry"], removed: ["# Old"])
        #expect(ChangedFiles.lineStats(raw) == (added: 3, removed: 1))
        #expect(ChangedFiles.path(args: [:], diff: raw) == "meal-plan.md", "the arrow header names the file")
        let (lines, _) = ChangedFiles.preview(raw)
        #expect(lines.map(\.text) == ["−# Old", "+# Meals", "+- Tacos", "+- Curry"], "no codes, no header, no ┊ line")

        let call = ToolCall(id: "w", name: "write_file", title: "Write meal-plan.md", argsText: #"{"path":"meal-plan.md"}"#,
                            summary: nil, state: .done, durationSeconds: 1)
        let c = try #require(card(ChatRowBuilder.build(input([.tool(call), .text("Done.")], diffs: ["w": raw]))))
        #expect(c.files.map(\.added) == [3] && c.files.map(\.removed) == [1])
    }

    @Test func showFileChangesOffDropsTheCard() {
        let (parts, diffs) = threeFiles
        var i = input(parts, diffs: diffs)
        i.activity.showFileChanges = false
        #expect(card(ChatRowBuilder.build(i)) == nil)
    }

    @Test func theCardStaysWhenStepsAreHidden() {
        let (parts, diffs) = threeFiles
        let rows = ChatRowBuilder.build(input(parts, diffs: diffs, style: .rows, hide: true))
        #expect(card(rows) != nil)
        #expect(previews(rows).isEmpty, "a hidden step carries no preview to hang under")
    }

    @Test func theCardWaitsForTheSameFoldThatRemovesTheSteps() {
        // §10.5 DECISION: gating on `folding` (not the vestigial `holdingActions`) lands the card in the same
        // rebuild the step rows disappear in, so it never arrives a beat early and bounces them.
        let (parts, diffs) = threeFiles
        #expect(card(ChatRowBuilder.build(input(parts, diffs: diffs, style: .rows, hide: true, folding: ["a"]))) == nil,
               "still fading: the card waits")
        #expect(card(ChatRowBuilder.build(input(parts, diffs: diffs, style: .rows, hide: true, folding: []))) != nil,
               "the fold landed: the card and the steps' removal are the same rebuild")
    }

    @Test func rowsAndBubblesShowEachEditsFirstLinesRightAfterItsOwnRow() throws {
        let (parts, diffs) = threeFiles
        for style in [ToolCallStyle.rows, .bubbles] {
            let rows = ChatRowBuilder.build(input(parts, diffs: diffs, style: style))
            let shown = previews(rows)
            #expect(shown.map(\.call.id) == ["e1", "e2", "e3"], "\(style)")
            let e2 = try #require(shown.first { $0.call.id == "e2" })
            #expect(e2.lines.map(\.text).first == "+new 0" && !e2.more)
            // Each preview follows its edit's own row.
            let at = try #require(rows.firstIndex { $0.id == "a|diffe1" })
            #expect(at > 0 && rows[at - 1].messageId == "a", "\(style)")
        }
    }

    @Test func oneLineAndAtTheBottomCarryNoPreview() {
        // §12 DECISION: One Line / At the Bottom have no per-call row to hang a preview from.
        let (parts, diffs) = threeFiles
        for style in [ToolCallStyle.line, .bottom] {
            #expect(previews(ChatRowBuilder.build(input(parts, diffs: diffs, style: style))).isEmpty, "\(style)")
            #expect(card(ChatRowBuilder.build(input(parts, diffs: diffs, style: style))) != nil, "\(style) still carries the card")
        }
    }

    @Test func aLargeDiffIsCappedAtEightLines() throws {
        let rows = ChatRowBuilder.build(input([.tool(edit("big", "huge.txt")), .text("ok")], diffs: ["big": diff(3000)], style: .rows))
        let p = try #require(previews(rows).first)
        #expect(p.lines.count == 8 && p.more)
    }

    @Test func sevenFilesShowFiveThenShowAll() throws {
        var parts: [ChatPart] = []
        var diffs: [String: String] = [:]
        for n in 0..<7 { parts.append(.tool(edit("e\(n)", "f\(n).swift"))); diffs["e\(n)"] = diff(n + 1) }
        parts.append(.text("Done."))
        let rows = ChatRowBuilder.build(input(parts, diffs: diffs))
        let row = try #require(rows.first { $0.id == "a|files" })
        let style = ChatStyleCache.shared.style(for: .large)
        guard case .activity(.changedFiles(let layout)) = TextLayout.make(row, width: 393, style: style).content else {
            Issue.record("no card layout"); return
        }
        #expect(layout.headerTitle == "7 files changed")
        #expect(layout.rows.count == 5 && layout.showAllTitle == "Show All 7 Files")
        #expect(layout.rows.allSatisfy { $0.frame.height >= 44 }, "every file row is a 44 pt target")
        #expect(layout.headerFrame.height >= 44, "the whole header is Review's own tap target")
        #expect(layout.rows[0].accessibility == "f0.swift, +1")
    }

    @Test func showAllTogglesOnTheRowsOwnExpandedKey() throws {
        // The row's id IS its `expanded` key (as `ToolBubbleRow`'s own "⋯ N earlier steps"): `chatCellToggle(rowId:)`
        // needs no row-kind-specific wiring.
        var parts: [ChatPart] = []
        var diffs: [String: String] = [:]
        for n in 0..<7 { parts.append(.tool(edit("e\(n)", "f\(n).swift"))); diffs["e\(n)"] = diff(n + 1) }
        parts.append(.text("Done."))
        var i = input(parts, diffs: diffs)
        let collapsed = try #require(card(ChatRowBuilder.build(i)))
        #expect(collapsed.showAll == false)
        i.expanded.insert("a|files")
        let expanded = try #require(card(ChatRowBuilder.build(i)))
        #expect(expanded.showAll == true && expanded.files.count == 7)
    }

    @Test func theCardFollowsExtraLargeText() throws {
        let (parts, diffs) = threeFiles
        let row = try #require(ChatRowBuilder.build(input(parts, diffs: diffs)).first { $0.id == "a|files" })
        let small = TextLayout.make(row, width: 393, style: ChatStyleCache.shared.style(for: .large))
        let big = TextLayout.make(row, width: 393, style: ChatStyleCache.shared.style(for: .accessibilityExtraLarge))
        #expect(big.height > small.height)
    }

    @Test func aRelativePathIsTheChatsFolders() {
        #expect(ChangedFiles.resolve("src/app.py", in: "/work/demo") == "/work/demo/src/app.py")
        #expect(ChangedFiles.resolve("./src/app.py", in: "/work/demo/") == "/work/demo/src/app.py")
        #expect(ChangedFiles.resolve("/etc/hosts", in: "/work/demo") == "/etc/hosts")
        #expect(ChangedFiles.resolve("src/app.py", in: nil) == "src/app.py")
    }

    // MARK: [files] Cards between helpers' deliveries fold into the run's one line (UpdateGroups.swift)

    /// Otto's chat (owner's screenshot, 2026-11-10): replies that did their work and said nothing, each with its card,
    /// between helpers' deliveries, then the answer.
    func longTurn(answer: [ChatPart] = [.text("All five checks pass.")]) -> ChatRowBuilder.Input {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        func note(_ id: String, _ n: Double) -> ChatMessage {
            ChatMessage(id: id, role: .system, parts: [.text("Subagent Task Completed: Check batch \(id)")], timestamp: t0.addingTimeInterval(n), rowId: nil)
        }
        func work(_ id: String, _ n: Double, _ edits: [ToolCall]) -> ChatMessage {
            ChatMessage(id: id, role: .assistant, parts: edits.map { .tool($0) }, timestamp: t0.addingTimeInterval(n), rowId: nil)
        }
        let messages = [
            ChatMessage(id: "u", role: .user, parts: [.text("run the review")], timestamp: t0, rowId: nil),
            work("w1", 10, [edit("e1", "TASK.json")]),
            note("n1", 20), note("n2", 21),
            work("w2", 30, [edit("e2", "check_consistency.py")]),
            note("n3", 40),
            work("w3", 50, [edit("e3", "parent-adjudications.json"), edit("e4", "analyze.py")]),
            work("w4", 60, [edit("e5", "analyze.py"), edit("e6", "analyze.py")]),
            note("n4", 70),
            ChatMessage(id: "a", role: .assistant, parts: answer, timestamp: t0.addingTimeInterval(80), rowId: nil),
        ]
        var activity = ActivityRowsInput()
        activity.style = .line
        var i = ChatRowBuilder.Input(messages: messages, isRunning: false, botName: "Otto", expanded: [], scope: "t", activity: activity)
        i.diffs = ["e1": diff(1), "e2": diff(2), "e3": diff(1), "e4": diff(2, 1), "e5": diff(1), "e6": diff(3, 2), "e9": diff(4)]
        return i
    }

    @Test func cardsBetweenHelpersFoldIntoOneLine() throws {
        var input = longTurn()
        let closed = ChatRowBuilder.build(input)
        #expect(card(closed) == nil, "no card stands in the chat")
        let lines = closed.compactMap { row -> (String, BackgroundResultRow)? in
            if case .backgroundResult(let b) = row.kind { return (row.id, b) } else { return nil }
        }
        #expect(lines.count == 1, "one line for the whole of it")
        let (lineId, line) = try #require(lines.first)
        // Four work lines, four helpers, and the cards as one.
        #expect(line.group?.count == 9 && line.group?.tail == "8 more")
        #expect(closed.filter { !$0.id.hasSuffix("|day") }.count == 3, "your message, the line, the answer")

        input.expanded = [lineId]
        let members = ChatRowBuilder.build(input).compactMap { row -> (String, UpdateMemberRow)? in
            if case .updateMember(let m) = row.kind { return (row.id, m) } else { return nil }
        }
        let files = members.filter { !$0.1.files.isEmpty }
        #expect(files.count == 1, "every card is one member")
        let (id, member) = try #require(files.first)
        #expect(id == "w4|files|in", "where the last card was")
        #expect(member.title == "4 files changed" && member.opens)
        #expect(member.preview == "TASK.json, check_consistency.py, parent-adjudications.json, analyze.py")
        let analyze = try #require(member.files.last)
        #expect(analyze.edits == 3 && analyze.added == 6 && analyze.removed == 3, "a file two replies changed is one row")

        // Opened: a row per file, then Review Changes.
        input.expanded = [lineId, id]
        let opened = try #require(ChatRowBuilder.build(input).first { $0.id == id })
        guard case .member(let m) = TextLayout.layout(opened, width: 390, style: ChatStyle.make(category: .large)).content else {
            Issue.record("expected a member layout"); return
        }
        #expect(m.files && m.steps.map(\.title) == ["TASK.json", "check_consistency.py", "parent-adjudications.json", "analyze.py", "Review Changes"])
        #expect(m.steps[3].detail == "3 edits · +6 −3")
    }

    @Test func aReplyWithWordsKeepsItsCardAndSoDoesOneWordlessReplyAlone() throws {
        // The answer changed a file too: its card stays under its words, and counts only its own files.
        let rows = ChatRowBuilder.build(longTurn(answer: [.tool(edit("e9", "REPORT.md")), .text("All five checks pass.")]))
        let c = try #require(card(rows))
        #expect(c.files.map(\.name) == ["REPORT.md"])
        #expect(rows.last?.id == "a|files")
        // One reply that said nothing, by itself: its line, then its card (as before).
        let alone = ChatRowBuilder.build(input([.tool(edit("e1", "src/app.py"))], diffs: ["e1": diff(2)]))
        #expect(card(alone) != nil && alone.last?.id == "a|files")
        #expect(!alone.contains { if case .backgroundResult = $0.kind { true } else { false } })
    }

    @Test func foldedCardsRebuildAsAFullBuildDraws() {
        func ids(_ rows: [ChatRow]) -> [String] { rows.map { "\($0.id)#\($0.fingerprint)#\($0.variant)#\($0.gapAbove)" } }
        let full = longTurn()
        let want = ids(ChatRowBuilder.build(full))
        for k in full.messages.indices {
            // Messages arriving: the first k were drawn, the rest land.
            var early = full
            early.messages = Array(full.messages.prefix(k))
            var model = ChatRowModel()
            model.rebuildAll(early, syncMessages: 100, oldestShown: nil)
            model.rebuildNewest(full, fromMessage: k)
            #expect(ids(model.allRows.reversed()) == want, "rebuildNewest from \(k)")
            // One reply's card lands late (its diffs arrive): rebuilding it alone redraws the run's line.
            var before = full
            before.diffs = [:]
            model = ChatRowModel()
            model.rebuildAll(before, syncMessages: 100, oldestShown: nil)
            model.rebuildMessages(full, 0...(full.messages.count - 1))
            model.rebuildMessages(full, k...k)
            #expect(ids(model.allRows.reversed()) == want, "rebuildMessages \(k)")
        }
        // A tap: the line opens, then its files member, each rebuilding only its own message (as `chatCellToggle` does).
        var open = full
        var model = ChatRowModel()
        model.rebuildAll(full, syncMessages: 100, oldestShown: nil)
        for id in ["w1|grp", "w4|files|in"] {
            open.expanded.insert(id)
            guard let row = model.allRows.first(where: { $0.id == id }),
                  let k = full.messages.firstIndex(where: { $0.id == row.messageId }) else { Issue.record("no row \(id)"); continue }
            model.rebuildMessages(open, k...k)
            #expect(ids(model.allRows.reversed()) == ids(ChatRowBuilder.build(open)), "toggling \(id)")
        }
    }
}
