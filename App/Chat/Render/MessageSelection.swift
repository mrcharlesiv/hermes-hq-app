import UIKit

// [mac] Mac audit 2026-11-02 #11 (docs/mac.md, "Selecting part of a message"): part of a message selected by dragging
// across it. The app draws its own text (`TextKitLayout` pieces in `BlockView`s), so the selection is the app's own
// too: two spots in the message's laid-out pieces, a highlight drawn under the text, and plain words taken from the
// pieces. This file is the pure part (no views, any thread); `ChatTextSelector` (App/Chat/Cells/ChatTextSelection.swift)
// turns a drag into spots and draws them. Rebuilt from F18 (fix/n20-macselect, Mac build 400), which never reached main.

/// A caret position in a message: the block (the message's text blocks, in order), the piece inside the block
/// (`PlacedBlock.pieces`) and the UTF-16 offset in that piece's text. Spots order as they read: block, piece, offset.
nonisolated struct TextSpot: Hashable, Comparable, Sendable {
    var block: Int
    var piece: Int
    var offset: Int

    static func < (a: TextSpot, b: TextSpot) -> Bool { (a.block, a.piece, a.offset) < (b.block, b.piece, b.offset) }
}

/// The selection inside one message: where the drag began (`anchor`) and where it is now (`focus`), either way round.
nonisolated struct MessageSelection: Hashable, Sendable {
    var anchor: TextSpot
    var focus: TextSpot

    var start: TextSpot { min(anchor, focus) }
    var end: TextSpot { max(anchor, focus) }
    var isEmpty: Bool { anchor == focus }

    /// The drag moved on: the anchor stays where it began.
    func extended(to spot: TextSpot) -> MessageSelection { MessageSelection(anchor: anchor, focus: spot) }

    /// The selected part of one piece, whose text is `length` UTF-16 units long; nil when none of it is selected.
    func range(block: Int, piece: Int, length: Int) -> NSRange? {
        guard !isEmpty else { return nil }
        let s = start, e = end
        if (block, piece) < (s.block, s.piece) || (block, piece) > (e.block, e.piece) { return nil }
        let from = (block, piece) == (s.block, s.piece) ? min(max(0, s.offset), length) : 0
        let to = (block, piece) == (e.block, e.piece) ? min(max(0, e.offset), length) : length
        return to > from ? NSRange(location: from, length: to - from) : nil
    }

    /// Every piece's selected range, by block then piece, for blocks whose pieces are `lengths`.
    func marks(lengths: [[Int]]) -> [[Int: NSRange]] {
        lengths.enumerated().map { b, pieces in
            var out: [Int: NSRange] = [:]
            for (p, length) in pieces.enumerated() {
                if let range = range(block: b, piece: p, length: length) { out[p] = range }
            }
            return out
        }
    }

    /// The whole of blocks whose pieces are `lengths` (nil when there is no text).
    static func all(lengths: [[Int]]) -> MessageSelection? {
        guard let first = lengths.firstIndex(where: { !$0.isEmpty }),
              let last = lengths.lastIndex(where: { !$0.isEmpty }), let tail = lengths[last].last else { return nil }
        let all = MessageSelection(anchor: TextSpot(block: first, piece: 0, offset: 0),
                                focus: TextSpot(block: last, piece: lengths[last].count - 1, offset: tail))
        return all.isEmpty ? nil : all
    }
}

nonisolated enum SelectionText {
    /// The words of `range` in drawn text, as they read. A formula or a code span selected whole gives what a click on
    /// it copies (`.chatCopy`: the TeX source, the code); a part of one gives the drawn characters. The drawing's own
    /// marks drop out: word joiners (a flag kept on one line), the narrow spaces padding a code span, attachment glyphs;
    /// a line break inside a paragraph (U+2028) is a line break.
    static func plain(_ text: NSAttributedString, range: NSRange) -> String {
        let range = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        guard range.length > 0 else { return "" }
        let ns = text.string as NSString
        var out = ""
        text.enumerateAttribute(.chatCopy, in: range) { value, part, _ in
            guard part.length > 0 else { return }
            if let whole = value as? String {
                // The span's own run (its padding included): whole when every drawn character of it is selected.
                var run = NSRange()
                _ = text.attribute(.chatCopy, at: part.location, longestEffectiveRange: &run,
                                   in: NSRange(location: 0, length: text.length))
                let drawn = clean(ns.substring(with: run), code: true)
                let picked = clean(ns.substring(with: part), code: true)
                out += picked == drawn ? whole : picked
            } else {
                out += clean(ns.substring(with: part), code: false)
            }
        }
        return out
    }

    private static func clean(_ s: String, code: Bool) -> String {
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u {
            case "\u{2060}", "\u{FFFC}": continue
            case "\u{202F}" where code: continue
            case "\u{2028}": scalars.append("\n")
            default: scalars.append(u)
            }
        }
        return String(scalars)
    }

    /// The selection's plain words across a message's blocks (each block's pieces, in order). Pieces of one block join
    /// as they are drawn: a table's next cell on the same row with a tab, a piece lower down with a line break. Blocks
    /// join with a blank line, as the Markdown had them.
    static func plain(_ selection: MessageSelection, blocks: [[TextPiece]]) -> String {
        guard !selection.isEmpty else { return "" }
        var parts: [String] = []
        for (b, pieces) in blocks.enumerated() where b >= selection.start.block && b <= selection.end.block {
            var text = ""
            var last: CGRect?
            for (p, piece) in pieces.enumerated() {
                guard let range = selection.range(block: b, piece: p, length: piece.text.length) else { continue }
                let words = plain(piece.text, range: range)
                if let last, !text.isEmpty, !text.hasSuffix("\n") {
                    text += abs(last.minY - piece.frame.minY) < 0.5 ? "\t" : "\n"
                }
                text += words
                last = piece.frame
            }
            while text.hasSuffix("\n") { text.removeLast() }
            while text.hasPrefix("\n") { text.removeFirst() }
            if !text.isEmpty { parts.append(text) }
        }
        return parts.joined(separator: "\n\n")
    }
}

nonisolated enum SelectionGeometry {
    /// Which of `frames` a point belongs to: the one it is in; else, of those level with it, the nearest sideways;
    /// else the nearest above or below (a point past the first or last runs to it). Nil only when there are none.
    static func nearest(_ point: CGPoint, in frames: [CGRect]) -> Int? {
        if let inside = frames.firstIndex(where: { $0.contains(point) }) { return inside }
        func dx(_ f: CGRect) -> CGFloat { point.x < f.minX ? f.minX - point.x : point.x > f.maxX ? point.x - f.maxX : 0 }
        func dy(_ f: CGRect) -> CGFloat { point.y < f.minY ? f.minY - point.y : point.y >= f.maxY ? point.y - f.maxY : 0 }
        var best: (index: Int, dy: CGFloat, dx: CGFloat)?
        for (i, f) in frames.enumerated() {
            let candidate = (index: i, dy: dy(f), dx: dx(f))
            if let b = best, (b.dy, b.dx) <= (candidate.dy, candidate.dx) { continue }
            best = candidate
        }
        return best?.index
    }
}
