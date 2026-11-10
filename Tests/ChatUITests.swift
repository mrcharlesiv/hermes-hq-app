import Foundation
import Testing
import UIKit
@testable import HermesHQNative

// MARK: - Markdown

@MainActor
struct MarkdownRendererTests {
    let style = ChatStyle.make(category: .large)

    private func textBlocks(_ r: RenderedMarkdown) -> [String] {
        r.blocks.compactMap { if case .text(let t) = $0 { return t.string } else { return nil } }
    }

    @Test func codeFenceBecomesCodeBlockWithLabel() {
        let r = MarkdownRenderer.render("Before\n\n```swift\nlet a = 1\nprint(a)\n```\n\nAfter", style: style)
        #expect(r.blocks.count == 3)
        guard case .code(let label, let code, let text, let lines) = r.blocks[1] else {
            Issue.record("expected a code block, got \(r.blocks[1])"); return
        }
        #expect(label == "Swift")
        #expect(code == "let a = 1\nprint(a)")      // no trailing newline
        #expect(text.string == code)
        #expect(lines == 2)
        #expect(!r.endsWithProse == false)          // ends with "After" (prose)
        let font = text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true)
    }

    @Test func codeFenceLabels() {
        #expect(MarkdownRenderer.codeLanguageLabel("py") == "Python")
        #expect(MarkdownRenderer.codeLanguageLabel("sh") == "Shell")
        #expect(MarkdownRenderer.codeLanguageLabel("yml") == "YAML")
        #expect(MarkdownRenderer.codeLanguageLabel("text") == nil)
        #expect(MarkdownRenderer.codeLanguageLabel("") == nil)
        #expect(MarkdownRenderer.codeLanguageLabel(nil) == nil)
        #expect(MarkdownRenderer.codeLanguageLabel("elixir") == "Elixir")
        #expect(MarkdownRenderer.codeLanguageLabel("!!weird") == nil)
    }

    @Test func emptyFenceIsDropped() {
        let r = MarkdownRenderer.render("Hi\n\n```\n\n```", style: style)
        #expect(r.blocks.count == 1)
    }

    @Test func tabsInCodeBecomeTwoSpaces() {
        let r = MarkdownRenderer.render("```\n\tindented\n```", style: style)
        guard case .code(_, let code, _, _) = r.blocks[0] else { Issue.record("no code block"); return }
        #expect(code == "  indented")
    }

    @Test func singleNewlineIsALineBreakInsideTheParagraph() {
        let r = MarkdownRenderer.render("first line\nsecond line\n\nnew paragraph", style: style)
        let texts = textBlocks(r)
        #expect(texts.count == 1)
        // A soft break is a line separator (same paragraph, no paragraph spacing); paragraphs split on "\n".
        #expect(texts[0] == "first line\u{2028}second line\nnew paragraph")
    }

    @Test func singleNewlineInListItemsAndQuotes() {
        let r = MarkdownRenderer.render("- one\n  still one\n\n> quoted\n> more", style: style)
        #expect(textBlocks(r).first?.contains("one\u{2028}still one") == true)
        guard case .quote(let q, nil) = r.blocks.last else { Issue.record("expected a quote"); return }
        #expect(q.string == "quoted\u{2028}more")
    }

    @Test func unorderedAndOrderedLists() {
        let r = MarkdownRenderer.render("- apple\n- pear\n  - nested\n\n3. three\n4. four", style: style)
        let text = textBlocks(r).joined()
        #expect(text.contains("•\tapple"))
        #expect(text.contains("•\tpear"))
        #expect(text.contains("◦\tnested"))
        #expect(text.contains("3.\tthree"))
        #expect(text.contains("4.\tfour"))
        // Nested items indent further than their parents.
        guard case .text(let t) = r.blocks[0] else { Issue.record("expected prose, got \(r.blocks[0])"); return }
        let ns = t.string as NSString
        let parent = t.attribute(.paragraphStyle, at: ns.range(of: "pear").location, effectiveRange: nil) as? NSParagraphStyle
        let child = t.attribute(.paragraphStyle, at: ns.range(of: "nested").location, effectiveRange: nil) as? NSParagraphStyle
        #expect((child?.headIndent ?? 0) > (parent?.headIndent ?? 0))
    }

    @Test func taskListCheckboxes() {
        let r = MarkdownRenderer.render("- [x] done\n- [ ] todo", style: style)
        let text = textBlocks(r).joined()
        #expect(text.contains("☑︎\tdone"))
        #expect(text.contains("☐\ttodo"))
    }

    @Test func linksAndBareURLs() {
        let r = MarkdownRenderer.render("See [docs](https://example.com/docs) or https://hermes.dev/x. Thanks", style: style)
        guard case .text(let t) = r.blocks[0] else { Issue.record("no text"); return }
        let ns = t.string as NSString
        let docs = t.attribute(.chatLink, at: ns.range(of: "docs").location, effectiveRange: nil) as? URL
        #expect(docs?.absoluteString == "https://example.com/docs")
        let bare = t.attribute(.chatLink, at: ns.range(of: "hermes.dev").location, effectiveRange: nil) as? URL
        #expect(bare?.absoluteString == "https://hermes.dev/x")          // trailing "." peels off
        #expect(t.attribute(.chatLink, at: ns.range(of: "Thanks").location, effectiveRange: nil) == nil)
    }

    @Test func noSmartPunctuation() {
        let r = MarkdownRenderer.render("a -- b \"quoted\"", style: style)
        #expect(textBlocks(r).first == "a -- b \"quoted\"")
    }

    @Test func emphasisStrongInlineCode() {
        let r = MarkdownRenderer.render("**bold** _it_ `code` ~~gone~~", style: style)
        guard case .text(let t) = r.blocks[0] else { Issue.record("expected prose, got \(r.blocks[0])"); return }
        let ns = t.string as NSString
        let bold = t.attribute(.font, at: ns.range(of: "bold").location, effectiveRange: nil) as? UIFont
        #expect(bold?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        let italic = t.attribute(.font, at: ns.range(of: "it").location, effectiveRange: nil) as? UIFont
        #expect(italic?.fontDescriptor.symbolicTraits.contains(.traitItalic) == true)
        let code = ns.range(of: "code").location
        #expect(t.attribute(.backgroundColor, at: code, effectiveRange: nil) != nil)
        #expect(t.attribute(.strikethroughStyle, at: ns.range(of: "gone").location, effectiveRange: nil) != nil)
    }

    @Test func tableIsAGridOfCells() {
        let r = MarkdownRenderer.render("| A | Bee |\n|---|---:|\n| 1 | **22** |", style: style)
        guard case .table(let t) = r.blocks[0] else { Issue.record("expected a table"); return }
        #expect(t.plain == "A\tBee\n1\t22")
        #expect(t.header.map(\.string) == ["A", "Bee"])
        #expect(t.rows.map { $0.map(\.string) } == [["1", "22"]])
        #expect(t.alignments == [.natural, .right])
        let bold = t.rows[0][1].attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        #expect(bold?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        #expect(!r.endsWithProse)
        // Laid out as a grid: one piece per filled cell, the right-aligned column flush right, a header row band.
        let row = ChatRow(id: "m|b0", messageId: "m", scope: "s", fingerprint: 1,
                          kind: .bubble(BubbleRow(mine: false, text: "| A | Bee |\n|---|---:|\n| 1 | **22** |", markdown: true,
                                                  partIndex: 0, joinsAbove: false, joinsBelow: false, tail: false, time: nil,
                                                  pending: false, streaming: false, speaker: nil)),
                          gapAbove: 0, variant: 0)
        guard case .bubble(let b) = TextLayout.make(row, width: 402, style: style).content,
              let placed = b.blocks.first, let grid = placed.grid else { Issue.record("expected a table block"); return }
        #expect(placed.pieces.count == 4)
        #expect(grid.rows.count == 3)                               // top, header bottom, last row bottom
        let right = placed.pieces[3].frame
        // The right-aligned column's words end at its padding (the Expand button is in the footer, not on the grid).
        #expect(abs(right.maxX - (grid.columns[2] - ChatMetrics.tableCellPadH)) < 0.6)
    }

    @Test func headingsAreLargerAndSemibold() {
        let r = MarkdownRenderer.render("# Title\n\nBody", style: style)
        guard case .text(let t) = r.blocks[0] else { Issue.record("expected prose, got \(r.blocks[0])"); return }
        let h = t.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        #expect((h?.pointSize ?? 0) > style.body.pointSize)
    }

    @Test func thematicBreakIsSpace() {
        let r = MarkdownRenderer.render("a\n\n---\n\nb", style: style)
        #expect(r.blocks.count == 3)
        if case .spacer(let h) = r.blocks[1] { #expect(h == 12) } else { Issue.record("expected a spacer") }
    }

    @Test func preprocessingStripsReasoningTags() {
        #expect(MarkdownPreprocess.run("<think>secret</think>\nHello") == "Hello")
        // While it streams, thinking still arriving on its own line is held back; once settled, only a preamble is
        // (a later line that merely starts with a tag keeps what follows it: audit 863).
        #expect(MarkdownPreprocess.run("Hello\n<thinking>half arrived", streaming: true) == "Hello\n")
        #expect(MarkdownPreprocess.run("<thinking>half arrived").isEmpty)
    }

    @Test func gfmAlert() {
        let r = MarkdownRenderer.render("> [!WARNING]\n> Careful here", style: style)
        guard case .quote(let t, let alert) = r.blocks[0] else { Issue.record("expected a quote"); return }
        #expect(alert?.title == "Warning")
        #expect(t.string == "Careful here")
    }
}

// MARK: - Text layout

@MainActor
struct TextLayoutTests {
    let style = ChatStyle.make(category: .large)

    private func bubbleRow(id: String = "m1", text: String = "Hello there", scope: String = "acct|default|s1",
                           variant: Int = 0, gap: CGFloat = 6, mine: Bool = false) -> ChatRow {
        ChatRow(id: "\(id)|b0", messageId: id, scope: scope,
                fingerprint: ChatRowBuilder.bubbleFingerprint(text, mine: mine, speaker: nil),
                kind: .bubble(BubbleRow(mine: mine, text: text, markdown: !mine, partIndex: 0, joinsAbove: false,
                                        joinsBelow: false, tail: true, time: nil, pending: false, streaming: false)),
                gapAbove: gap, variant: variant)
    }

    @Test func keyEqualityAndDifferences() {
        let base = TextLayoutKey(row: bubbleRow(), width: 402, category: .large)
        #expect(base == TextLayoutKey(row: bubbleRow(), width: 402, category: .large))
        #expect(base.messageId == "m1")
        #expect(base.part == "b0")
        #expect(base != TextLayoutKey(row: bubbleRow(text: "Hello there!"), width: 402, category: .large))
        #expect(base != TextLayoutKey(row: bubbleRow(scope: "acct|other|s9"), width: 402, category: .large))
        #expect(base != TextLayoutKey(row: bubbleRow(variant: 7), width: 402, category: .large))
        #expect(base != TextLayoutKey(row: bubbleRow(gap: 2), width: 402, category: .large))
        #expect(base != TextLayoutKey(row: bubbleRow(), width: 390, category: .large))
        #expect(base != TextLayoutKey(row: bubbleRow(), width: 402, category: .extraLarge))
        #expect(base != TextLayoutKey(row: bubbleRow(id: "m2"), width: 402, category: .large))
        // Widths round to half points, so sub-pixel jitter reuses the layout.
        #expect(base == TextLayoutKey(row: bubbleRow(), width: 402.1, category: .large))
    }

    @Test func differentPartsOfOneMessageHaveDifferentKeys() {
        var other = bubbleRow()
        other = ChatRow(id: "m1|b3", messageId: "m1", scope: other.scope, fingerprint: other.fingerprint, kind: other.kind,
                        gapAbove: 6, variant: 0)
        #expect(TextLayoutKey(row: bubbleRow(), width: 402, category: .large) != TextLayoutKey(row: other, width: 402, category: .large))
    }

    @Test func cacheReturnsTheSameLayout() {
        let row = bubbleRow(id: "cache-\(UUID().uuidString)")
        let a = TextLayout.layout(row, width: 402, style: style)
        #expect(TextLayout.cached(row, width: 402, style: style) != nil)
        let b = TextLayout.layout(row, width: 402, style: style)
        #expect(a.height == b.height)
        #expect(a.key == TextLayoutKey(row: row, width: 402, category: .large))
    }

    @Test func heightsAreWholePointsAndGrowWithText() {
        let short = TextLayout.make(bubbleRow(id: "s", text: "Hi"), width: 402, style: style)
        let long = TextLayout.make(bubbleRow(id: "l", text: String(repeating: "word ", count: 120)), width: 402, style: style)
        #expect(short.height == short.height.rounded())
        #expect(long.height > short.height)
        // One line of body text plus padding and the turn gap.
        #expect(short.height >= style.bodyLineHeight + 14 + 6)
    }

    @Test func bubbleWidthRespectsMaximum() {
        let text = String(repeating: "long text ", count: 40)
        let mine = ChatRow(id: "u|b0", messageId: "u", scope: "t", fingerprint: ChatRowBuilder.bubbleFingerprint(text, mine: true, speaker: nil),
                           kind: .bubble(BubbleRow(mine: true, text: text, markdown: false,
                                                   partIndex: 0, joinsAbove: false, joinsBelow: false, tail: true, time: Date(),
                                                   pending: false, streaming: false)), gapAbove: 6, variant: 0)
        guard case .bubble(let b) = TextLayout.make(mine, width: 402, style: style).content else { Issue.record("not a bubble"); return }
        #expect(b.frame.width <= 320)
        #expect(abs(b.frame.maxX - (402 - 16)) < 0.01)              // trailing, 16 pt in
        #expect(b.timeText != nil)
    }

    @Test func cellDrawsExactlyTheMeasuredLayout() {
        // The bubble cell places its bubble, blocks and text pieces at the frames TextLayout measured.
        let text = "Some **bold** text that wraps across a few lines of a bubble, with `code` too.\n\n```swift\nlet a = 1\nlet b = 2\nlet c = 3\n```\n\nAfter the code."
        let row = bubbleRow(id: "cell-\(UUID().uuidString)", text: text)
        let layout = TextLayout.layout(row, width: 402, style: style)
        guard case .bubble(let b) = layout.content else { Issue.record("not a bubble"); return }
        let cell = ChatBubbleCell(style: .default, reuseIdentifier: ChatBubbleCell.reuse)
        cell.frame = CGRect(x: 0, y: 0, width: 402, height: layout.height)
        cell.configure(row, layout: layout)
        guard let bubble = cell.contentView.subviews.first else { Issue.record("no bubble view"); return }
        #expect(bubble.frame == b.frame)
        let blocks = bubble.subviews.compactMap { $0 as? BlockView }.filter { !$0.isHidden }
        #expect(blocks.count == b.blocks.count)
        for (view, placed) in zip(blocks, b.blocks) {
            #expect(view.frame == placed.frame)
            #expect(view.pieceTexts.map(\.frame) == placed.pieces.map(\.frame))
            // Every piece's measured height is what TextKit lays the piece out at for drawing.
            for piece in placed.pieces {
                #expect(TextKitLayout(piece.text, width: placed.layoutWidth).size.height == piece.frame.height)
            }
        }
        #expect(layout.height == ceil(b.frame.maxY))
    }
}

// MARK: - Rows

@MainActor
struct ChatRowBuilderTests {
    private func msg(_ id: String, _ role: ChatMessage.Role, _ parts: [ChatPart], at t: TimeInterval) -> ChatMessage {
        ChatMessage(id: id, role: role, parts: parts, timestamp: Date(timeIntervalSince1970: 1_790_000_000 + t), rowId: nil)
    }

    private func build(_ messages: [ChatMessage], running: Bool = false) -> [ChatRow] {
        ChatRowBuilder.build(.init(messages: messages, isRunning: running, botName: "Hermes", expanded: []))
    }

    @Test func runsShareCornersAndOnlyTheLastHasTailAndTime() {
        let rows = build([
            msg("u1", .user, [.text("one")], at: 0),
            msg("u2", .user, [.text("two")], at: 60),
            msg("a1", .assistant, [.text("reply")], at: 90),
        ])
        let bubbles = rows.compactMap { row -> (String, BubbleRow)? in
            if case .bubble(let b) = row.kind { return (row.messageId, b) } else { return nil }
        }
        #expect(bubbles.count == 3)
        #expect(bubbles[0].1.joinsBelow && !bubbles[0].1.tail && bubbles[0].1.time == nil)
        #expect(bubbles[1].1.joinsAbove && bubbles[1].1.tail && bubbles[1].1.time != nil)
        #expect(bubbles[2].1.tail && !bubbles[2].1.joinsAbove)
        // 2 pt inside a run, 6 pt between turns.
        #expect(rows.first(where: { $0.messageId == "u2" })?.gapAbove == 2)
        #expect(rows.first(where: { $0.messageId == "a1" })?.gapAbove == 6)
    }

    @Test func daySeparatorAtFirstMessageAndAfterLongGap() {
        let rows = build([
            msg("u1", .user, [.text("one")], at: 0),
            msg("u2", .user, [.text("two")], at: 100),
            msg("u3", .user, [.text("three")], at: 4000),
        ])
        let days = rows.filter { if case .day = $0.kind { return true } else { return false } }.map(\.messageId)
        #expect(days == ["u1", "u3"])
    }

    @Test func consecutiveToolCallsFoldIntoOneRow() {
        func call(_ id: String, _ name: String, _ args: String, _ state: ToolCall.State = .done) -> ChatPart {
            .tool(ToolCall(id: id, name: name, title: name, argsText: args, summary: nil, state: state, durationSeconds: nil))
        }
        let rows = build([msg("a", .assistant, [
            call("1", "read_file", #"{"path":"a/b.swift"}"#),
            call("2", "terminal", #"{"command":"ls"}"#),
            call("3", "todo", "{}"),                       // successful silent tool: no row, no count
            .text("Done."),
            call("4", "edit_file", #"{"path":"x/y.ts"}"#), // file edits stand alone
        ], at: 0)])
        let tools = rows.compactMap { row -> ToolRunRow? in if case .toolRun(let t) = row.kind { return t } else { return nil } }
        #expect(tools.count == 2)
        #expect(tools[0].tools.map(\.id) == ["1", "2"])
        #expect(ChatRunSummary.summarize(tools[0].tools, live: false) == "Explored b.swift, ran 1 command")
        #expect(ChatRunSummary.summarize(tools[1].tools, live: false) == "Edited y.ts")
    }

    @Test func waitingCapsuleWhileRunningBeforeAnyReply() {
        let rows = build([msg("u", .user, [.text("hi")], at: 0)], running: true)
        if case .waiting = rows.last?.kind {} else { Issue.record("expected the waiting row last") }
    }

    @Test func rangeBuildMatchesFullBuild() {
        let messages = (0..<20).map { i in
            msg("m\(i)", i % 3 == 0 ? .assistant : .user, [.text("text \(i)")], at: Double(i) * (i % 5 == 0 ? 4000 : 100))
        }
        let input = ChatRowBuilder.Input(messages: messages, isRunning: false, botName: "Hermes", expanded: [])
        let full = ChatRowBuilder.build(input)
        let parts = ChatRowBuilder.build(input, range: 0..<8) + ChatRowBuilder.build(input, range: 8..<20)
        #expect(full.map(\.id) == parts.map(\.id))
        #expect(full.map(\.variant) == parts.map(\.variant))
        #expect(full.map(\.gapAbove) == parts.map(\.gapAbove))
    }

    @Test func stoppedAndErrorMarks() {
        var stopped = msg("a", .assistant, [.text("partial")], at: 0)
        stopped.interrupted = true
        var failed = msg("b", .assistant, [], at: 10)
        // A failure the app has no words for keeps its own ("overloaded" became the provider card's, n20 revisit).
        failed.error = "the tool runner went away"
        let rows = build([stopped, failed])
        #expect(rows.contains { if case .caption("Stopped") = $0.kind { return true } else { return false } })
        #expect(rows.contains { if case .error(let e) = $0.kind { return e.reason == "the tool runner went away" } else { return false } })
    }
}

// MARK: - Run summaries

struct ChatRunSummaryTests {
    private func call(_ name: String, _ args: String, _ state: ToolCall.State = .done) -> ToolCall {
        ToolCall(id: UUID().uuidString, name: name, title: name, argsText: args, summary: nil, state: state, durationSeconds: nil)
    }

    @Test func wording() {
        #expect(ChatRunSummary.summarize([call("terminal", #"{"command":"npm run typecheck"}"#)], live: false) == "Ran 1 command")
        #expect(ChatRunSummary.summarize([call("terminal", #"{"command":"cd app && npm run typecheck 2>&1 | tail -20"}"#, .running)], live: true)
                == "Running npm run typecheck")
        #expect(ChatRunSummary.summarize([call("read_file", #"{"path":"a"}"#), call("read_file", #"{"path":"b"}"#),
                                          call("list_files", "{}")], live: false) == "Explored 3 files")
        #expect(ChatRunSummary.summarize([call("web_search", #"{"query":"hermes agent"}"#)], live: false) == "Searched “hermes agent”")
        #expect(ChatRunSummary.summarize([call("web_extract", #"{"urls":["https://example.com/docs"]}"#)], live: false) == "Read example.com/docs")
        #expect(ChatRunSummary.summarize([call("web_extract", #"{"urls":["https://a.com","https://b.com","https://c.com"]}"#)], live: false) == "Read 3 pages")
        #expect(ChatRunSummary.summarize([call("browser_click", "{}"), call("terminal", #"{"command":"ls"}"#, .failed)], live: false)
                == "Performed 1 browser action, ran 1 command, 1 tool call failed")
        #expect(ChatRunSummary.summarize([call("skill_view", #"{"name":"pdf"}"#)], live: false) == "Loaded skill: pdf")
    }

    @Test func shellCommandSummaries() {
        #expect(ChatRunSummary.summarizeShellCommand("cd /x && make test") == "make test")
        #expect(ChatRunSummary.summarizeShellCommand("npm test 2>&1") == "npm test")
        #expect(ChatRunSummary.summarizeShellCommand("a; b; c") == "a + 2 commands")
        #expect(ChatRunSummary.summarizeShellCommand("echo \"--- done\"; ls") == "ls")
    }

    @Test func glyphFromSummary() {
        #expect(ChatRunSummary.glyph(forSummary: "Edited a.ts") == .file)
        #expect(ChatRunSummary.glyph(forSummary: "Explored 2 files, ran 1 command") == .explore)
        #expect(ChatRunSummary.glyph(forSummary: "Ran 3 commands") == .terminal)
        #expect(ChatRunSummary.glyph(forSummary: "Searched “x”") == .other)
    }
}

// MARK: - Cache scope and per-part fingerprints

@MainActor
struct ChatCacheScopeTests {
    let style = ChatStyle.make(category: .large)
    let now = Date(timeIntervalSince1970: 1_790_100_000)

    private func rows(_ messages: [ChatMessage], scope: String, running: Bool = false) -> [ChatRow] {
        ChatRowBuilder.build(.init(messages: messages, isRunning: running, botName: "Ivy", expanded: [], now: now, scope: scope))
    }

    private func reply(_ text: String) -> ChatMessage {
        ChatMessage(id: "stored-row-12-assistant", role: .assistant, parts: [.text(text)], timestamp: now, rowId: 12)
    }

    private func text(of layout: RowLayout) -> String {
        guard case .bubble(let b) = layout.content else { return "" }
        return b.blocks.flatMap(\.pieces).map(\.text.string).joined()
    }

    /// The reviewer's repro: another bot's chat with the same row ids (both revision 0) must draw its own words.
    @Test func sameIdsInAnotherChatDrawTheirOwnText() {
        let first = rows([reply("Hello from the first bot")], scope: "acct|alpha|s1")
        let second = rows([reply("OTHER BOT: a different reply")], scope: "acct|beta|s7")
        // (The reply's bubble: the Copy row follows the latest reply.)
        let a = TextLayout.layout(first.last { $0.isBubble }!, width: 402, style: style)
        let b = TextLayout.layout(second.last { $0.isBubble }!, width: 402, style: style)
        #expect(text(of: a).contains("first bot"))
        #expect(text(of: b).contains("OTHER BOT"))
        #expect(a.key != b.key)
    }

    @Test func sameIdSameScopeDifferentTextNeverHits() {
        // A reused id with different content in the same chat (history replaced) can't hit the old layout either.
        let first = rows([reply("Version one")], scope: "acct|alpha|s1")
        let second = rows([reply("Version two, longer")], scope: "acct|alpha|s1")
        let a = TextLayout.layout(first.last { $0.isBubble }!, width: 402, style: style)
        let b = TextLayout.layout(second.last { $0.isBubble }!, width: 402, style: style)
        #expect(text(of: a).contains("one"))
        #expect(text(of: b).contains("two"))
    }

    @Test func differentScopeSameTextHasDifferentKeys() {
        let a = rows([reply("Same words")], scope: "acct|alpha|s1").last!
        let b = rows([reply("Same words")], scope: "acct|beta|s1").last!
        #expect(TextLayoutKey(row: a, width: 402, category: .large) != TextLayoutKey(row: b, width: 402, category: .large))
    }

    @Test func finishedPartsKeepTheirFingerprintWhileALaterPartStreams() {
        var m = ChatMessage(id: "local-a1", role: .assistant, parts: [
            .text("First part, finished."),
            .tool(ToolCall(id: "t1", name: "terminal", title: "terminal", argsText: #"{"command":"ls"}"#, summary: nil, state: .done, durationSeconds: nil)),
            .text("Second part is stre"),
        ], timestamp: now, rowId: nil)
        m.isStreaming = true
        let before = rows([m], scope: "s", running: true)
        m.parts[2] = .text("Second part is streaming more words")
        m.revision += 1
        let after = rows([m], scope: "s", running: true)
        func row(_ rows: [ChatRow], _ id: String) -> ChatRow? { rows.first { $0.id == id } }
        #expect(row(before, "local-a1|b0")?.fingerprint == row(after, "local-a1|b0")?.fingerprint)
        #expect(row(before, "local-a1|tt1")?.fingerprint == row(after, "local-a1|tt1")?.fingerprint)
        #expect(row(before, "local-a1|b2")?.fingerprint != row(after, "local-a1|b2")?.fingerprint)
        // The finished part's rendered text is the very same object (no re-parse, no redraw).
        guard let b0 = row(after, "local-a1|b0"), case .bubble(let bubble) = b0.kind,
              let b0Before = row(before, "local-a1|b0"), case .bubble(let bubbleBefore) = b0Before.kind else {
            Issue.record("missing bubble"); return
        }
        let r1 = TextLayout.rendered(bubbleBefore, row: b0Before, style: style)
        let r2 = TextLayout.rendered(bubble, row: b0, style: style)
        guard case .text(let t1) = r1.blocks[0], case .text(let t2) = r2.blocks[0] else { Issue.record("no prose"); return }
        #expect(t1 === t2)
    }

    @Test func toolRowFingerprintFollowsItsCalls() {
        func message(_ state: ToolCall.State, args: String) -> ChatMessage {
            ChatMessage(id: "a", role: .assistant, parts: [
                .tool(ToolCall(id: "t1", name: "read_file", title: "read_file", argsText: args, summary: nil, state: state, durationSeconds: nil)),
                .tool(ToolCall(id: "t2", name: "terminal", title: "terminal", argsText: #"{"command":"ls"}"#, summary: nil, state: .done, durationSeconds: nil)),
            ], timestamp: now, rowId: nil)
        }
        let running = rows([message(.running, args: #"{"path":"a.swift"}"#)], scope: "s").first { $0.id == "a|tt1" }
        let done = rows([message(.done, args: #"{"path":"a.swift"}"#)], scope: "s").first { $0.id == "a|tt1" }
        let other = rows([message(.done, args: #"{"path":"b.swift"}"#)], scope: "s").first { $0.id == "a|tt1" }
        #expect(running?.fingerprint != done?.fingerprint)
        #expect(done?.fingerprint != other?.fingerprint)
    }

    @Test func dayAndErrorRowsCarryTheirLabelsInputs() {
        let m = ChatMessage(id: "u", role: .user, parts: [.text("hi")], timestamp: now, rowId: 1)
        let today = ChatRowBuilder.build(.init(messages: [m], isRunning: false, botName: "Ivy", expanded: [], now: now, scope: "s"))
        let tomorrow = ChatRowBuilder.build(.init(messages: [m], isRunning: false, botName: "Ivy", expanded: [],
                                                  now: now.addingTimeInterval(86_400), scope: "s"))
        #expect(today.first?.fingerprint != tomorrow.first?.fingerprint)   // "Today" became "Yesterday"
        var failed = reply("partial")
        failed.error = "the tool runner went away"   // the card's own title, "Ivy couldn't finish this reply"
        let ivy = rows([failed], scope: "s").first { $0.id.hasSuffix("|err") }
        let ann = ChatRowBuilder.build(.init(messages: [failed], isRunning: false, botName: "Ann", expanded: [], now: now, scope: "s"))
            .first { $0.id.hasSuffix("|err") }
        #expect(ivy?.fingerprint != ann?.fingerprint)
    }

    @Test func errorReasonRule() {
        #expect(ChatRowBuilder.errorReason("overloaded") == "overloaded")
        #expect(ChatRowBuilder.errorReason("   ") == "Hermes ended this turn without a reply.")
        #expect(ChatRowBuilder.errorReason(String(repeating: "x", count: 161)).hasPrefix("Something went wrong"))
        #expect(ChatRowBuilder.errorReason("line one\nline two").hasPrefix("Something went wrong"))
    }
}

// MARK: - Markdown limits

struct MarkdownComplexityTests {
    @Test func verdicts() {
        #expect(MarkdownComplexity.verdict("Hello **there**, a [link](https://x.y).") == .simple)
        #expect(MarkdownComplexity.verdict(String(repeating: "> ", count: 3000) + "deep") == .tooComplex)
        #expect(MarkdownComplexity.verdict(String(repeating: "> ", count: 33) + "deep") == .tooComplex)
        #expect(MarkdownComplexity.verdict(String(repeating: "> ", count: 20) + "deep") == .deep)
        #expect(MarkdownComplexity.verdict(String(repeating: "*", count: 300) + "a") == .tooComplex)
        #expect(MarkdownComplexity.verdict(String(repeating: "*a ", count: 600)) == .tooComplex)
        #expect(MarkdownComplexity.verdict(String(repeating: "[", count: 1200)) == .tooComplex)
        #expect(MarkdownComplexity.verdict(String(repeating: " ", count: 1200) + "x") == .tooComplex)
        // A long run inside a fence is code, not emphasis.
        #expect(MarkdownComplexity.verdict("```\n" + String(repeating: "*", count: 300) + "\n```") != .tooComplex)
        #expect(MarkdownComplexity.verdict("      - indented list " + String(repeating: " ", count: 0)) == .simple)
        #expect(MarkdownComplexity.verdict(String(repeating: " ", count: 130) + "- item") == .tooComplex)
    }

    /// The reviewer's crash: 3,000 nested quotes rendered on a GCD thread (512 KB stack) overflowed the stack.
    @Test func deepNestingRendersPlainOnABackgroundThread() async {
        let style = ChatStyle.make(category: .large)
        let source = String(repeating: "> ", count: 3000) + "deep"
        let rendered = await Task.detached { MarkdownRenderer.render(source, style: style) }.value
        guard case .text(let t) = rendered.blocks.first else { Issue.record("expected plain text"); return }
        #expect(t.string.hasSuffix("deep"))
        #expect(t.string.hasPrefix(">"))
    }

    @Test func deepButAllowedNestingParsesOnTheBigStack() async {
        let style = ChatStyle.make(category: .large)
        let source = String(repeating: "> ", count: 30) + "**deep** quote"
        let rendered = await withCheckedContinuation { (done: CheckedContinuation<UncheckedSendable<RenderedMarkdown>, Never>) in
            DispatchQueue.global(qos: .utility).async {
                done.resume(returning: UncheckedSendable(MarkdownRenderer.render(source, style: style)))
            }
        }.value
        guard case .quote(let q, nil) = rendered.blocks.first else { Issue.record("expected a quote, got \(rendered.blocks)"); return }
        #expect(q.string == "deep quote")
    }

    @Test func emphasisBombIsPlain() {
        let style = ChatStyle.make(category: .large)
        let bomb = String(repeating: "*a ", count: 700)
        let r = MarkdownRenderer.render(bomb, style: style)
        guard case .text(let t) = r.blocks.first else { Issue.record("expected plain text"); return }
        #expect(t.string == bomb)
    }
}

// MARK: - Long text, clamps, tool arguments

@MainActor
struct LongContentTests {
    let style = ChatStyle.make(category: .large)

    private func row(_ id: String, _ text: String, mine: Bool = false, expanded: Bool = false, openCode: Set<Int> = []) -> ChatRow {
        ChatRow(id: "\(id)|b0", messageId: id, scope: "long", fingerprint: ChatRowBuilder.bubbleFingerprint(text, mine: mine, speaker: nil),
                kind: .bubble(BubbleRow(mine: mine, text: text, markdown: !mine, partIndex: 0, joinsAbove: false, joinsBelow: false,
                                        tail: true, time: nil, pending: false, streaming: false, expanded: expanded, openCode: openCode)),
                gapAbove: 6, variant: expanded ? 1 : openCode.count + 2)
    }

    @Test func longProseIsCutIntoPiecesThatAddUp() {
        let text = FakeChatSession.longReply(paragraphs: 22)
        let r = MarkdownRenderer.render(text, style: style)
        guard case .text(let whole) = r.blocks[0] else { Issue.record("expected prose"); return }
        let parts = TextSplit.split(whole, maxLength: 2_000)
        #expect(parts.count > 1)
        #expect(parts.allSatisfy { $0.text.length <= 2_000 })
        // The pieces hold every character but the cut separators.
        #expect(parts.map(\.text.string).joined().count == whole.string.count - (parts.count - 1))
        // Stacked with their gaps, the pieces are as tall as the whole (±1 pt of rounding per piece).
        let width: CGFloat = 350
        let full = TextKitLayout(whole, width: width).size.height
        let stacked = parts.enumerated().reduce(CGFloat(0)) { sum, item in
            sum + (item.offset > 0 ? item.element.gapBefore : 0) + TextKitLayout(item.element.text, width: width).size.height
        }
        #expect(abs(stacked - full) <= CGFloat(parts.count))
    }

    @Test func aHugeReplyNeverMakesATallPiece() {
        let layout = TextLayout.make(row("huge", FakeChatSession.longReply(paragraphs: 30)), width: 402, style: style)
        guard case .bubble(let b) = layout.content else { Issue.record("not a bubble"); return }
        let pieces = b.blocks.flatMap(\.pieces)
        #expect(pieces.count > 8)
        #expect(pieces.allSatisfy { $0.frame.height < 1_600 })
    }

    @Test func codeClampsAt120AndOpensTo40PercentOfTheScreen() {
        let fence = "```python\n" + (0..<300).map { "x\($0) = \($0)" }.joined(separator: "\n") + "\n```"
        let closed = TextLayout.make(row("code", fence), width: 402, style: style)
        guard case .bubble(let b) = closed.content, case .code = b.blocks[0].block else { Issue.record("no code block"); return }
        #expect(b.blocks[0].codeOpen == false)
        #expect(b.blocks[0].textFrame.height == ChatMetrics.codeClamp)
        #expect(b.blocks[0].contentHeight > 1_000)
        let open = TextLayout.make(row("code", fence, openCode: [0]), width: 402, style: style)
        guard case .bubble(let o) = open.content else { Issue.record("not a bubble"); return }
        #expect(o.blocks[0].codeOpen == true)
        #expect(o.blocks[0].textFrame.height == (TextLayout.screenHeight * 0.4).rounded())
        // Short code never clamps.
        let short = TextLayout.make(row("short", "```swift\nlet a = 1\nlet b = 2\nlet c = 3\n```"), width: 402, style: style)
        guard case .bubble(let s) = short.content else { Issue.record("not a bubble"); return }
        #expect(s.blocks[0].codeOpen == nil)
    }

    @Test func yourLongMessageClampsAtTenLinesWithShowMore() {
        let text = (1...24).map { "Line \($0)" }.joined(separator: "\n")
        let clamped = TextLayout.make(row("mine", text, mine: true), width: 402, style: style)
        guard case .bubble(let c) = clamped.content else { Issue.record("not a bubble"); return }
        #expect(c.showMoreFrame != nil)
        #expect(c.blocks[0].textFrame.height == style.bodyLineHeight * 10 + 2)
        #expect(c.blocks[0].fadesBottom)
        let full = TextLayout.make(row("mine", text, mine: true, expanded: true), width: 402, style: style)
        guard case .bubble(let f) = full.content else { Issue.record("not a bubble"); return }
        #expect(f.showMoreFrame == nil)
        #expect(full.height > clamped.height)
        // A short message never clamps.
        let short = TextLayout.make(row("short", "Hi", mine: true), width: 402, style: style)
        guard case .bubble(let s) = short.content else { Issue.record("not a bubble"); return }
        #expect(s.showMoreFrame == nil)
    }

    @Test func bigToolArgumentsAreScannedNotParsed() {
        let big = #"{"path":"src/generated/schema.json","content":""# + String(repeating: "abcdefghij", count: 20_000) + #""}"#
        let call = ToolCall(id: "w", name: "write_file", title: "write_file", argsText: big, summary: nil, state: .done, durationSeconds: nil)
        #expect(ChatRunSummary.args(call)["path"]?.string == "src/generated/schema.json")
        #expect(ChatRunSummary.summarize([call], live: false) == "Edited schema.json")
        let urls = #"{"urls":["https://a.com/x","https://b.com"],"pad":""# + String(repeating: "z", count: 9_000) + #""}"#
        let extract = ToolCall(id: "e", name: "web_extract", title: "web_extract", argsText: urls, summary: nil, state: .done, durationSeconds: nil)
        #expect(ChatRunSummary.summarize([extract], live: false) == "Read 2 pages")
        let escaped = #"{"command":"cd /x && ls -la \"dir\"","pad":""# + String(repeating: "z", count: 9_000) + #""}"#
        let run = ToolCall(id: "r", name: "terminal", title: "terminal", argsText: escaped, summary: nil, state: .running, durationSeconds: nil)
        #expect(ChatRunSummary.summarize([run], live: true) == #"Running ls -la "dir""#)
    }

    @Test func waitWords() {
        #expect(ChatWaitingCell.words(label: "Ivy is thinking…", elapsed: 4) == "Ivy is thinking…")
        #expect(ChatWaitingCell.words(label: "Ivy is thinking…", elapsed: 12) == "Ivy is thinking… · 0:12")
        // Past a minute it says the bot is still at it, with the clock, never "No reply yet" (owner, 2026-10-29).
        #expect(ChatWaitingCell.words(label: "Ivy is thinking…", long: "Ivy is still thinking…", elapsed: 75) == "Ivy is still thinking… · 1:15")
        #expect(ChatWaitingCell.words(label: "Ivy is reading a.md…", long: "Ivy is still working…", elapsed: 75) == "Ivy is still working… · 1:15")
        #expect(ChatWaitingCell.words(label: "Ivy is running npm test…", long: "Ivy is still working…", elapsed: 75, doing: true) == "Ivy is running npm test… · 1:15")
        #expect(ChatWaitingCell.words(label: "Retrying in 8s…", elapsed: 75) == "Retrying in 8s… · 1:15")
        // The desktop's timer beside the words (`formatElapsed`).
        #expect(ChatWaitingCell.elapsed(0) == "")
        #expect(ChatWaitingCell.elapsed(9) == "")
        #expect(ChatWaitingCell.elapsed(12) == "· 0:12")
        #expect(ChatWaitingCell.elapsed(65) == "· 1:05")
    }
}

// MARK: - Row bookkeeping

@MainActor
struct ChatRowModelTests {
    let now = Date(timeIntervalSince1970: 1_790_200_000)

    /// A chat of `count` messages: users, replies with tool runs and reasoning, notices, a failed and a stopped turn.
    private func chat(_ count: Int, prefix: String = "m", start: TimeInterval = 0) -> [ChatMessage] {
        (0..<count).map { i in
            let t = Date(timeIntervalSince1970: 1_790_000_000 + start + Double(i) * (i % 7 == 0 ? 4000 : 90))
            switch i % 5 {
            case 0, 3:
                return ChatMessage(id: "\(prefix)\(i)", role: .user, parts: [.text("question \(i)")], timestamp: t, rowId: i)
            case 4 where i % 20 == 4:
                return ChatMessage(id: "\(prefix)\(i)", role: .system, parts: [.text("Model changed")], timestamp: t, rowId: i)
            default:
                var m = ChatMessage(id: "\(prefix)\(i)", role: .assistant, parts: [
                    .reasoning("thinking \(i)"),
                    .tool(ToolCall(id: "\(prefix)\(i)-t", name: "read_file", title: "read_file", argsText: #"{"path":"f\#(i).swift"}"#,
                                   summary: nil, state: .done, durationSeconds: nil)),
                    .text("answer **\(i)**"),
                ], timestamp: t, rowId: i)
                if i % 11 == 1 { m.error = "overloaded" }
                if i % 13 == 2 { m.interrupted = true }
                return m
            }
        }
    }

    private func input(_ messages: [ChatMessage], running: Bool = false, expanded: Set<String> = []) -> ChatRowBuilder.Input {
        ChatRowBuilder.Input(messages: messages, isRunning: running, botName: "Ivy", expanded: expanded, now: now, scope: "test")
    }

    /// Builds every unbuilt chunk the way the background fill does.
    private func fill(_ model: inout ChatRowModel, _ input: ChatRowBuilder.Input) {
        while let range = model.nextChunk(size: 37) {
            model.appendBuilt(ChatRowBuilder.build(input, range: range), range: range, generation: model.generation, measured: true)
        }
    }

    private func expectMatchesFullBuild(_ model: ChatRowModel, _ input: ChatRowBuilder.Input,
                                        sourceLocation: SourceLocation = #_sourceLocation) {
        let expected = Array(ChatRowBuilder.build(input).reversed())
        #expect(model.allRows.map(\.id) == expected.map(\.id), sourceLocation: sourceLocation)
        #expect(model.allRows.map(\.fingerprint) == expected.map(\.fingerprint), sourceLocation: sourceLocation)
        #expect(model.allRows.map(\.variant) == expected.map(\.variant), sourceLocation: sourceLocation)
        #expect(model.allRows.map(\.gapAbove) == expected.map(\.gapAbove), sourceLocation: sourceLocation)
        #expect(model.hiddenOlder >= 0 && model.hiddenOlder <= model.allRows.count, sourceLocation: sourceLocation)
        #expect(model.measuredHidden <= model.hiddenOlder, sourceLocation: sourceLocation)
    }

    @Test func openThenFillMatchesTheFullBuild() {
        let messages = chat(300)
        var model = ChatRowModel()
        model.rebuildAll(input(messages), syncMessages: 50, oldestShown: nil)
        #expect(model.shownCount == 0)
        #expect(model.builtFrom == 250)
        model.reveal(30)
        #expect(model.shownCount == 30)
        fill(&model, input(messages))
        expectMatchesFullBuild(model, input(messages))
        #expect(model.shownCount == 30)
    }

    /// Verify round 2 (a trap seen under load): the messages shrank without a reset; rebuilding the newest rows must not
    /// read past the end, and the model reports itself stale so the screen rebuilds it whole.
    @Test func shrunkMessagesNeverTrapAndReadAsStale() {
        let long = chat(120)
        var model = ChatRowModel()
        model.rebuildAll(input(long), syncMessages: 1, oldestShown: nil)
        #expect(model.builtFrom == 119)
        let short = Array(long.prefix(40))
        #expect(model.isStale(forMessageCount: short.count))
        model.rebuildNewest(input(short), touching: [short[short.count - 1].id])
        model.rebuildNewest(input(short), fromMessage: 39)
        model.rebuildAll(input(short), syncMessages: 10, oldestShown: nil)
        #expect(!model.isStale(forMessageCount: short.count))
    }

    @Test func appendAndStreamAtTheNewestEnd() {
        var messages = chat(120)
        var model = ChatRowModel()
        model.rebuildAll(input(messages), syncMessages: 40, oldestShown: nil)
        model.reveal(25)
        // Your message, the waiting capsule, then a streaming reply that grows.
        messages.append(ChatMessage(id: "local-u", role: .user, parts: [.text("new")], timestamp: now, rowId: nil))
        model.rebuildNewest(input(messages, running: true), touching: ["local-u"])
        #expect(model.allRows.first?.id == "waiting")
        var reply = ChatMessage(id: "local-a", role: .assistant, parts: [.text("Hel")], timestamp: now, rowId: nil)
        reply.isStreaming = true
        messages.append(reply)
        model.rebuildNewest(input(messages, running: true), touching: ["local-a"])
        messages[messages.count - 1].parts = [.text("Hello there, streaming")]
        model.rebuildNewest(input(messages, running: true), touching: ["local-a"])
        // Your bubble, the reply and the day separator before them joined the shown rows.
        let added = ChatRowBuilder.build(input(messages, running: true)).filter { ["local-u", "local-a"].contains($0.messageId) }.count
        #expect(added == 3)
        // The Copy row under the old latest reply went once a newer message arrived.
        let copyRows = ChatRowBuilder.build(input(chat(120))).filter { if case .actions = $0.kind { true } else { false } }.count
        #expect(model.shownCount == 25 - copyRows + added)
        fill(&model, input(messages, running: true))
        expectMatchesFullBuild(model, input(messages, running: true))
    }

    @Test func prependOlderWhileRowsAreHidden() {
        let older = chat(80, prefix: "o", start: -1_000_000)
        var messages = chat(150)
        var model = ChatRowModel()
        model.rebuildAll(input(messages), syncMessages: 60, oldestShown: nil)
        model.reveal(20)
        fill(&model, input(messages))
        #expect(model.hiddenOlder > 0)
        messages.insert(contentsOf: older, at: 0)
        model.rebuildOldest(input(messages), added: older.count)
        fill(&model, input(messages))
        expectMatchesFullBuild(model, input(messages))
        #expect(model.shownCount == 20)
    }

    @Test func prependOlderWhenEverythingIsShown() {
        let older = chat(30, prefix: "o", start: -1_000_000)
        var messages = chat(40)
        var model = ChatRowModel()
        model.rebuildAll(input(messages), syncMessages: 160, oldestShown: nil)
        model.reveal(model.allRows.count)
        messages.insert(contentsOf: older, at: 0)
        model.rebuildOldest(input(messages), added: older.count)
        fill(&model, input(messages))
        expectMatchesFullBuild(model, input(messages))
    }

    @Test func resetAfterFillKeepsTheReaderInPlace() {
        var messages = chat(400)
        var model = ChatRowModel()
        model.rebuildAll(input(messages), syncMessages: 50, oldestShown: nil)
        fill(&model, input(messages))
        model.reveal(200)
        let oldestShown = model.shown.last!.messageId
        // Fresh history: same ids, new words.
        for i in messages.indices where messages[i].role == .user { messages[i].parts = [.text("fresh \(i)")] }
        model.rebuildAll(input(messages), syncMessages: 50, oldestShown: oldestShown)
        #expect(model.shown.last?.messageId == oldestShown)
        fill(&model, input(messages))
        expectMatchesFullBuild(model, input(messages))
    }

    @Test func removedMessagesRebuildLikeAReset() {
        var messages = chat(90)
        var model = ChatRowModel()
        model.rebuildAll(input(messages), syncMessages: 30, oldestShown: nil)
        model.reveal(15)
        let oldest = model.shown.last!.messageId
        messages.removeLast(3)
        model.rebuildAll(input(messages), syncMessages: 30, oldestShown: oldest)
        fill(&model, input(messages))
        expectMatchesFullBuild(model, input(messages))
    }

    @Test func toggleDeepInHistoryRebuildsOnlyThatMessage() {
        let messages = chat(300)
        var model = ChatRowModel()
        model.rebuildAll(input(messages), syncMessages: 300, oldestShown: nil)
        model.reveal(model.allRows.count - 10)
        let target = messages[12]
        let toolRow = "\(target.id)|t\(target.id)-t"
        let expanded: Set<String> = [toolRow]
        model.rebuildMessages(input(messages, expanded: expanded), 12...12)
        expectMatchesFullBuild(model, input(messages, expanded: expanded))
        let row = model.allRows.first { $0.id == toolRow }
        if case .toolRun(let t) = row?.kind { #expect(t.expanded) } else { Issue.record("no tool row") }
        // A message straddling the hidden boundary.
        var straddle = ChatRowModel()
        straddle.rebuildAll(input(messages), syncMessages: 300, oldestShown: nil)
        let boundaryMessage = messages.firstIndex { $0.id == straddle.allRows[straddle.allRows.count - 1 - 5].messageId }!
        straddle.reveal(straddle.allRows.count - 5)
        let boundaryId = messages[boundaryMessage].id
        let opened: Set<String> = ["\(boundaryId)|t\(boundaryId)-t", "\(boundaryId)|r0"]
        straddle.rebuildMessages(input(messages, expanded: opened), boundaryMessage...boundaryMessage)
        expectMatchesFullBuild(straddle, input(messages, expanded: opened))
    }

    /// [perf] Two cards apart rebuild as two runs; the replies between them stay as they were, in order.
    @Test func separateRunsRebuildOnlyTheirMessages() {
        #expect(ChatRowModel.runs(of: [9, 3, 1, 4, 4]) == [1...1, 3...4, 9...9])
        #expect(ChatRowModel.runs(of: []).isEmpty)
        let messages = chat(60)
        var model = ChatRowModel()
        model.rebuildAll(input(messages), syncMessages: 60, oldestShown: nil)
        model.reveal(model.allRows.count)
        let a = 41, b = 51, newest = messages.count - 1
        let between = Set(messages[(a + 1)..<b].map(\.id))
        let before = model.allRows.filter { between.contains($0.messageId) }.map(\.id)
        let opened: Set<String> = ["\(messages[a].id)|t\(messages[a].id)-t", "\(messages[b].id)|t\(messages[b].id)-t"]
        for run in ChatRowModel.runs(of: [b, a, newest]) { model.rebuildMessages(input(messages, expanded: opened), run) }
        #expect(model.allRows.filter { between.contains($0.messageId) }.map(\.id) == before)
        expectMatchesFullBuild(model, input(messages, expanded: opened))
    }

    @Test func staleChunkIsDropped() {
        var messages = chat(200)
        var model = ChatRowModel()
        model.rebuildAll(input(messages), syncMessages: 50, oldestShown: nil)
        let range = model.nextChunk(size: 50)!
        let staleRows = ChatRowBuilder.build(input(messages), range: range)
        let generation = model.generation
        // A message in that range changed before the chunk landed.
        messages[range.lowerBound + 3].parts = [.text("edited")]
        model.rebuildNewest(input(messages), touching: [messages[range.lowerBound + 3].id])
        let accepted = model.appendBuilt(staleRows, range: range, generation: generation, measured: true)
        #expect(!accepted)
        fill(&model, input(messages))
        expectMatchesFullBuild(model, input(messages))
    }

    @Test func revealHideAndMeasureBookkeeping() {
        let messages = chat(300)
        var model = ChatRowModel()
        model.rebuildAll(input(messages), syncMessages: 300, oldestShown: nil)
        model.reveal(50)
        #expect(model.measuredHidden == 0)
        let batch = model.nextToMeasure(max: 40)!
        model.markMeasured(batch.count, firstId: batch.first!.id)
        #expect(model.measuredHidden == 40)
        model.markMeasured(10, firstId: "not-the-next-row")
        #expect(model.measuredHidden == 40)
        model.reveal(30)
        #expect(model.shownCount == 80 && model.measuredHidden == 10)
        model.hide(keeping: 45)
        #expect(model.shownCount == 45 && model.measuredHidden == 45)
        #expect(model.nextToMeasure(max: 5)?.first?.id == model.allRows[45 + 45].id)
    }
}

// MARK: - Diff

struct ChatRowDiffTests {
    private func row(_ id: String, _ fingerprint: Int = 0) -> ChatRow {
        ChatRow(id: id, messageId: id, scope: "d", fingerprint: fingerprint, kind: .notice(id), gapAbove: 6, variant: 0)
    }

    /// UITableView's batch semantics: delete by old index, then insert by new index.
    private func applied(_ old: [ChatRow], _ d: ChatRowDiff, _ new: [ChatRow]) -> [String] {
        var ids = old.map(\.id)
        for i in d.deletes.sorted(by: >) { ids.remove(at: i) }
        for i in d.inserts.sorted() { ids.insert(new[i].id, at: i) }
        return ids
    }

    @Test func scriptedSequences() {
        let base = (0..<20).map { row("r\($0)") }
        var cases: [[ChatRow]] = []
        cases.append([row("new")] + base)                                     // appended at the newest end
        cases.append(Array(base.dropFirst(2)))                                 // removed at the newest end
        cases.append(base + (0..<5).map { row("old\($0)") })                   // revealed at the old end
        cases.append(Array(base.prefix(8)))                                    // hidden (trim)
        cases.append([row("waiting")] + base.dropFirst())                      // capsule replaced the newest row
        var middle = base
        middle.insert(row("mid"), at: 10)
        middle.remove(at: 3)
        cases.append(middle)                                                   // a rebuilt region in the middle
        for new in cases {
            let d = ChatRowDiff.make(old: base, new: new[...])
            #expect(applied(base, d, new) == new.map(\.id))
            #expect(d.changed.isEmpty)
        }
    }

    @Test func changedRowsInPlace() {
        let old = (0..<6).map { row("r\($0)") }
        var new = old
        new[0] = row("r0", 99)
        new[4] = row("r4", 7)
        let d = ChatRowDiff.make(old: old, new: new[...])
        #expect(d.inserts.isEmpty && d.deletes.isEmpty)
        #expect(Set(d.changed) == [0, 4])
        #expect(d.front + d.back >= old.count)
    }
}

// MARK: - Screen lifecycle

@MainActor
final class SpyChatSession: ChatSessionModel {
    let title = "Spy"
    let profile = "spy"
    let head: JSONValue? = nil
    var messages: [ChatMessage] = [
        ChatMessage(id: "u", role: .user, parts: [.text("hi")], timestamp: Date(), rowId: 1),
        ChatMessage(id: "a", role: .assistant, parts: [.text("hello")], timestamp: Date(), rowId: 2),
    ]
    var isRunning = false
    var hasOlder = false
    var isLoadingOlder = false
    var connection: ConnectionState = .ready
    var statusText: String? = nil
    var onChange: ((ChatChange) -> Void)?
    var starts = 0
    var stops = 0
    func start() { starts += 1 }
    func stopObserving() { stops += 1 }
    func loadOlder() {}
    func send(_ text: String) {}
    func stop() {}
}

@MainActor
struct ChatScreenLifecycleTests {
    @Test func removedWhileNotOnTopStopsObserving() {
        let spy = SpyChatSession()
        let chat = ChatViewController(session: spy)
        let root = UIViewController()
        let nav = UINavigationController(rootViewController: root)
        nav.pushViewController(chat, animated: false)
        chat.loadViewIfNeeded()
        #expect(spy.starts == 1)
        #expect(spy.onChange != nil)
        // Bot Info above it, then popToRoot / a stack swap: the chat gets no appearance callbacks.
        nav.pushViewController(UIViewController(), animated: false)
        nav.setViewControllers([root], animated: false)
        #expect(chat.parent == nil)
        #expect(spy.stops == 1)
        #expect(spy.onChange == nil)
    }

    @Test func placeholderAndSendFollowTheConnection() async throws {
        let spy = SpyChatSession()
        let chat = ChatViewController(session: spy)
        chat.loadViewIfNeeded()
        #expect(chat.composer.placeholder == "Message Spy")
        #expect(chat.composer.isEnabled)
        // [connect-fast] A quick reconnect shows nothing: the words wait 2 s, as the headers' subtitle does.
        spy.connection = .reconnecting(attempt: 1)
        spy.onChange?(.state)
        #expect(chat.composer.isEnabled)
        #expect(chat.composer.placeholder == "Message Spy")
        spy.connection = .ready
        spy.onChange?(.state)
        try await Task.sleep(for: .milliseconds(2300))
        #expect(chat.composer.placeholder == "Message Spy")
        // One that lasts says so after the wait.
        spy.connection = .reconnecting(attempt: 1)
        spy.onChange?(.state)
        try await Task.sleep(for: .milliseconds(2300))
        #expect(!chat.composer.isEnabled)
        #expect(chat.composer.placeholder == "Reconnecting…")
        spy.connection = .ready
        spy.onChange?(.state)
        #expect(chat.composer.isEnabled)
        #expect(chat.composer.placeholder == "Message Spy")
    }
}
