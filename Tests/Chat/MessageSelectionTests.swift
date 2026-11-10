// [mac] Mac audit 2026-11-02 #11 (docs/mac.md, "Selecting part of a message"): the pure rules of selecting part of a
// message with the mouse (spots, ranges, the caret under a point, the plain words with links, code spans, formulas and
// tables), ported from F18's tests (fix/n20-macselect f342cc11). The drag itself is Mac only and checked with
// `-HQDebugMacShotsSelect`.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@Suite("Message selection: rules")
@MainActor
struct MessageSelectionRuleTests {
    let style = ChatStyle.make(category: .large)

    private func layout(_ string: String, width: CGFloat = 240) -> TextKitLayout {
        TextKitLayout(NSAttributedString(string: string, attributes: [.font: style.body]), width: width)
    }

    // MARK: Spots and ranges

    @Test func spotsOrderAsTheyReadAndADragBackwardsSelectsTheSame() {
        let a = TextSpot(block: 0, piece: 1, offset: 9)
        let b = TextSpot(block: 1, piece: 0, offset: 2)
        #expect(a < b && TextSpot(block: 0, piece: 0, offset: 50) < a)
        let forward = MessageSelection(anchor: a, focus: b)
        let backward = MessageSelection(anchor: b, focus: a)
        #expect(forward.start == a && forward.end == b)
        #expect(backward.start == a && backward.end == b)
        #expect(MessageSelection(anchor: a, focus: a).isEmpty)
        // The anchor stays where the drag began.
        let moved = forward.extended(to: TextSpot(block: 0, piece: 0, offset: 3))
        #expect(moved.anchor == a && moved.start == TextSpot(block: 0, piece: 0, offset: 3) && moved.end == a)
    }

    @Test func eachPieceGetsItsPartOfTheSelection() {
        let s = MessageSelection(anchor: TextSpot(block: 0, piece: 1, offset: 4), focus: TextSpot(block: 2, piece: 0, offset: 6))
        #expect(s.range(block: 0, piece: 0, length: 20) == nil, "before the start")
        #expect(s.range(block: 0, piece: 1, length: 20) == NSRange(location: 4, length: 16), "from the start to the piece's end")
        #expect(s.range(block: 1, piece: 3, length: 7) == NSRange(location: 0, length: 7), "a piece in between: all of it")
        #expect(s.range(block: 2, piece: 0, length: 20) == NSRange(location: 0, length: 6), "to the end")
        #expect(s.range(block: 2, piece: 1, length: 20) == nil, "after the end")
        // Offsets past a piece that got shorter (a reply re-rendered) are clamped; nothing selected gives nil.
        #expect(s.range(block: 2, piece: 0, length: 3) == NSRange(location: 0, length: 3))
        let one = MessageSelection(anchor: TextSpot(block: 0, piece: 0, offset: 5), focus: TextSpot(block: 0, piece: 0, offset: 2))
        #expect(one.range(block: 0, piece: 0, length: 10) == NSRange(location: 2, length: 3))
        #expect(one.range(block: 0, piece: 0, length: 1) == nil)
    }

    // MARK: The caret under a point

    @Test func aPointFindsTheCaretBesideTheCharacterItIsOn() throws {
        let tk = layout("Hello world\nSecond line")
        let box = try #require(tk.rects(for: NSRange(location: 2, length: 1)).first)   // the first "l"
        #expect(tk.insertionIndex(at: CGPoint(x: box.minX + 1, y: box.midY)) == 2, "its left half: before it")
        #expect(tk.insertionIndex(at: CGPoint(x: box.maxX - 1, y: box.midY)) == 3, "its right half: after it")
        #expect(tk.insertionIndex(at: CGPoint(x: -20, y: box.midY)) == 0, "left of the line: its start")
        #expect(tk.insertionIndex(at: CGPoint(x: 2_000, y: box.midY)) == 11, "right of the line: before its break, never past it")
        #expect(tk.insertionIndex(at: CGPoint(x: 50, y: -10)) == 0, "above the text: the start")
        #expect(tk.insertionIndex(at: CGPoint(x: 0, y: tk.size.height + 10)) == tk.text.length, "below the text: the end")
        let second = try #require(tk.rects(for: NSRange(location: 12, length: 1)).first)
        #expect(tk.insertionIndex(at: CGPoint(x: second.minX + 1, y: second.midY)) == 12, "the second line's first character")
        #expect(layout("").insertionIndex(at: .zero) == 0)
    }

    @Test func aPointBelongsToTheFrameItIsInElseTheNearest() {
        let frames = [CGRect(x: 0, y: 0, width: 100, height: 20), CGRect(x: 120, y: 0, width: 80, height: 20),
                      CGRect(x: 0, y: 40, width: 100, height: 20)]
        #expect(SelectionGeometry.nearest(CGPoint(x: 130, y: 10), in: frames) == 1, "inside")
        #expect(SelectionGeometry.nearest(CGPoint(x: 300, y: 10), in: frames) == 1, "past a row's last cell: that cell")
        #expect(SelectionGeometry.nearest(CGPoint(x: 50, y: 32), in: frames) == 2, "between two lines: the nearer")
        #expect(SelectionGeometry.nearest(CGPoint(x: 50, y: -40), in: frames) == 0, "above everything: the first")
        #expect(SelectionGeometry.nearest(CGPoint(x: 50, y: 500), in: frames) == 2, "below everything: the last")
        #expect(SelectionGeometry.nearest(.zero, in: []) == nil)
    }

    // MARK: Plain words

    @Test func aLinkCopiesAsItsWordsAndACodeSpanWithoutItsDrawing() throws {
        let rendered = MarkdownRenderer.render("Install it for **one user** with `--break-system-packages`, see the [guide](https://example.com/g).",
                                               style: style)
        guard case .text(let text) = try #require(rendered.blocks.first) else { Issue.record("not prose"); return }
        #expect(text.string.contains("\u{2060}"), "the flag is drawn with word joiners (L307)")
        let all = SelectionText.plain(text, range: NSRange(location: 0, length: text.length))
        #expect(all == "Install it for one user with --break-system-packages, see the guide.", "\(all.debugDescription)")
        // Part of the code span: its drawn characters, without the joiners or the narrow padding.
        let ns = text.string as NSString
        let flag = ns.range(of: "break")
        let part = SelectionText.plain(text, range: NSRange(location: flag.location, length: 12))
        #expect(!part.contains("\u{2060}") && !part.contains("\u{202F}"))
        #expect(part.hasPrefix("break"), "\(part.debugDescription)")
        // The link's words, without the address.
        let guide = ns.range(of: "guide")
        #expect(SelectionText.plain(text, range: guide) == "guide")
    }

    @Test func aFormulaSelectedWholeCopiesItsSourceAndAPartCopiesWhatIsDrawn() {
        // As the formula renderer draws one ([transcript] F17 `MathStyle`): runs in two faces, each carrying its source.
        let source = "E = mc^2"
        let drawn = NSMutableAttributedString(string: "So ")
        drawn.append(NSAttributedString(string: "E", attributes: [.font: style.body, .chatCopy: source]))
        drawn.append(NSAttributedString(string: " = ", attributes: [.font: UIFont.systemFont(ofSize: 17), .chatCopy: source]))
        drawn.append(NSAttributedString(string: "mc²", attributes: [.font: style.body, .chatCopy: source]))
        drawn.append(NSAttributedString(string: " holds."))
        #expect(SelectionText.plain(drawn, range: NSRange(location: 0, length: drawn.length)) == "So E = mc^2 holds.")
        #expect(SelectionText.plain(drawn, range: NSRange(location: 3, length: 7)) == source, "the formula alone")
        #expect(SelectionText.plain(drawn, range: NSRange(location: 7, length: 3)) == "mc²", "a part of it: as drawn")
        // A line break inside a paragraph is a line break.
        let soft = NSAttributedString(string: "one\u{2028}two")
        #expect(SelectionText.plain(soft, range: NSRange(location: 0, length: 7)) == "one\ntwo")
    }

    @Test func piecesAndBlocksJoinAsTheyAreDrawn() {
        func piece(_ s: String, x: CGFloat, y: CGFloat) -> TextPiece {
            TextPiece(text: NSAttributedString(string: s), frame: CGRect(x: x, y: y, width: 60, height: 18))
        }
        let prose = [piece("First paragraph.", x: 0, y: 0), piece("Second one.", x: 0, y: 30)]
        let table = [piece("Step", x: 0, y: 0), piece("Time", x: 80, y: 0), piece("Build", x: 0, y: 24), piece("3 ms", x: 80, y: 24)]
        let code = [piece("let a = 1\n", x: 0, y: 0)]
        let blocks = [prose, table, code]
        let all = MessageSelection(anchor: TextSpot(block: 0, piece: 0, offset: 0), focus: TextSpot(block: 2, piece: 0, offset: 10))
        #expect(SelectionText.plain(all, blocks: blocks)
                == "First paragraph.\nSecond one.\n\nStep\tTime\nBuild\t3 ms\n\nlet a = 1", "\(SelectionText.plain(all, blocks: blocks).debugDescription)")
        let middle = MessageSelection(anchor: TextSpot(block: 1, piece: 3, offset: 1), focus: TextSpot(block: 0, piece: 1, offset: 7))
        #expect(SelectionText.plain(middle, blocks: blocks) == "one.\n\nStep\tTime\nBuild\t3", "a drag upwards, from inside a cell")
        #expect(SelectionText.plain(MessageSelection(anchor: all.start, focus: all.start), blocks: blocks).isEmpty)
    }

    @Test func selectAllTakesEveryPieceWithTextAndMarksFollowTheSelection() throws {
        // ⌘A: from the first block with text to the end of the last (a chip block between has no pieces).
        let all = try #require(MessageSelection.all(lengths: [[], [12, 5], [], [7]]))
        #expect(all.start == TextSpot(block: 1, piece: 0, offset: 0) && all.end == TextSpot(block: 3, piece: 0, offset: 7))
        #expect(MessageSelection.all(lengths: [[], []]) == nil && MessageSelection.all(lengths: [[0]]) == nil)
        let marks = all.marks(lengths: [[], [12, 5], [], [7]])
        #expect(marks.count == 4 && marks[0].isEmpty && marks[2].isEmpty)
        #expect(marks[1] == [0: NSRange(location: 0, length: 12), 1: NSRange(location: 0, length: 5)])
        #expect(marks[3] == [0: NSRange(location: 0, length: 7)])
    }
}
