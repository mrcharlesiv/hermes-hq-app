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
}
