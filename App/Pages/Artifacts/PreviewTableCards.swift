// [preview-tables] 2026-11-05 owner: a .md file's table in the Preview read as scattered words ("Sender / confirmed /
// MailPrefs / 2026-10-18 / active to"): the Preview is one text view, and a table wider than the page, set as tabbed
// lines, wrapped every column onto the next line. A table is now the chat's own table card (`BlockView`): the grid
// with its header band, sideways scrolling with edge fades when it is wider than the page, and the footer whose
// Expand (or a tap on the cells) opens the Table page. The text keeps one attachment character as tall as the card,
// and the card is laid over it.

import UIKit

/// A table's place in a flattened Preview: as wide as the text column, as tall as the card. Its cells are laid out
/// with the text (off the main thread); they don't depend on the page's width, only the card's visible width does.
nonisolated final class PreviewTableAttachment: NSTextAttachment, @unchecked Sendable {
    let table: MarkdownTable
    let pieces: [TextPiece]
    let grid: TableGrid
    /// The grid's height plus the footer's.
    let height: CGFloat

    init(table: MarkdownTable, style: ChatStyle) {
        let laid = TextLayout.tableGrid(table, style: style, keep: false, minWidth: ChatMetrics.tableStripMinWidth)
        self.table = table
        pieces = laid.pieces
        grid = laid.grid
        height = laid.grid.size.height + ChatMetrics.tableFooter(style)
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        let padding = textContainer?.lineFragmentPadding ?? 0
        return CGRect(x: 0, y: 0, width: max(1, lineFrag.width - 2 * padding), height: height)
    }

    /// Nothing drawn in the text: the card covers the place (nil would draw TextKit's file placeholder).
    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> UIImage? {
        UIImage()
    }
}

/// Lays a `BlockView` table card over each `PreviewTableAttachment` in a TextKit 1 text view (`ChatLayoutManager.textView`).
@MainActor
final class PreviewTableCards: NSObject {
    private weak var textView: UITextView?
    private let onExpand: (MarkdownTable) -> Void
    private var cards: [BlockView] = []
    /// What each card was last configured with, so a relayout that moves nothing keeps its sideways scroll.
    private var placed: [(attachment: ObjectIdentifier, frame: CGRect)] = []
    private var width: CGFloat = 0

    init(textView: UITextView, onExpand: @escaping (MarkdownTable) -> Void) {
        self.textView = textView
        self.onExpand = onExpand
    }

    func placeIfWidthChanged() {
        guard let textView, textView.bounds.width != width else { return }
        place()
    }

    /// Puts a card on every table in the text view's current text (none in Source, or for a text without tables).
    func place() {
        guard let textView else { return }
        width = textView.bounds.width
        let storage = textView.textStorage
        var found: [(PreviewTableAttachment, Int)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let attachment = value as? PreviewTableAttachment { found.append((attachment, range.location)) }
        }
        while cards.count > found.count { cards.removeLast().removeFromSuperview(); placed.removeLast() }
        defer { exposeControls() }
        guard !found.isEmpty else { return }
        let manager = textView.layoutManager, container = textView.textContainer
        let inset = textView.textContainerInset
        let column = max(1, container.size.width - 2 * container.lineFragmentPadding)
        for (i, (attachment, index)) in found.enumerated() {
            let glyph = manager.glyphIndexForCharacter(at: index)
            manager.ensureLayout(forGlyphRange: NSRange(location: 0, length: glyph + 1))
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let at = manager.location(forGlyphAt: glyph)   // the attachment's bottom sits on the line's baseline
            let w = min(column, attachment.grid.size.width)
            let frame = CGRect(x: line.minX + at.x + inset.left, y: line.minY + at.y - attachment.height + inset.top,
                               width: w, height: attachment.height).integral
            let card: BlockView
            if i < cards.count {
                card = cards[i]
                if placed[i].attachment == ObjectIdentifier(attachment), placed[i].frame == frame { continue }
                placed[i] = (ObjectIdentifier(attachment), frame)
            } else {
                card = makeCard()
                textView.addSubview(card)
                cards.append(card)
                placed.append((ObjectIdentifier(attachment), frame))
            }
            let grid = attachment.grid
            card.configure(PlacedBlock(block: .table(attachment.table), frame: frame,
                                       textFrame: CGRect(x: 0, y: 0, width: w, height: grid.size.height),
                                       contentWidth: grid.size.width, contentHeight: grid.size.height, layoutWidth: nil,
                                       pieces: attachment.pieces, codeOpen: nil, grid: grid), mine: false)
            card.accessibilityIdentifier = "artifact.table.\(i)"
        }
    }

    /// A text view is one accessibility element, which hides the views inside it: each card's Expand is listed beside
    /// it on the page instead, so VoiceOver (and a UI test) reaches it.
    private func exposeControls() {
        guard let textView, let page = textView.superview else { return }
        let controls = cards.flatMap(\.accessibleControls)
        page.accessibilityElements = controls.isEmpty ? nil : [textView] + controls
    }

    private func makeCard() -> BlockView {
        let card = BlockView()
        card.onExpandTable = { [weak self] table in self?.onExpand(table) }
        card.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        return card
    }

    /// A tap on the cells opens the Table page too, as in a reply.
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard let card = gesture.view as? BlockView else { return }
        _ = card.expandTableIfHit(gesture.location(in: card))
    }
}
