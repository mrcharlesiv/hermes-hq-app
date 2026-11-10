import UIKit

// Tapback badges under a message (ChatGatewayExtras.swift): one capsule per emoji, with a count past one, on the
// message's side and tucked in from the bubble's corner. Yours is in your bubble's colour and, with Message Reactions
// on, taps off. Frames come from the precomputed layout, like every chat row.

nonisolated struct ReactionsLayout: @unchecked Sendable {
    struct Chip {
        var frame: CGRect
        var text: NSAttributedString
        var mine: Bool
    }
    var chips: [Chip]
    var spoken: String
    /// Your badge's target (at least 44 pt), when you have one.
    var mineTap: CGRect?
}

extension TextLayout {
    nonisolated static let reactionInset: CGFloat = 10

    nonisolated static func reactions(_ r: ReactionsRow, gap: CGFloat, width: CGFloat, style: ChatStyle) -> RowLayout {
        let font = style.notice
        let height = ceil(font.lineHeight) + 8
        let side = ChatMetrics.sideInset + reactionInset
        let available = max(60, width - 2 * side)
        var chips: [ReactionsLayout.Chip] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        for chip in r.chips {
            let words = chip.count > 1 ? "\(chip.emoji) \(chip.count)" : chip.emoji
            let text = NSAttributedString(string: words, attributes: [
                .font: font, .foregroundColor: chip.mine ? ChatPalette.meText : ChatPalette.label2,
            ])
            let w = ceil(text.size().width) + 16
            if x > 0, x + w > available { x = 0; y += height + 4 }
            chips.append(.init(frame: CGRect(x: x, y: y, width: max(height, w), height: height), text: text, mine: chip.mine))
            x += max(height, w) + 4
        }
        let rowH = y + height
        // Lines run from the message's side: yours from the trailing edge, the bot's from the leading one.
        for i in chips.indices {
            var f = chips[i].frame
            f.origin.y += gap
            f.origin.x = r.mine ? width - side - f.maxX : side + f.minX
            chips[i].frame = f
        }
        let mine = chips.first(where: \.mine).map { c in
            c.frame.insetBy(dx: -max(0, (44 - c.frame.width) / 2), dy: -max(0, (44 - c.frame.height) / 2))
        }
        return RowLayout(height: ceil(gap + rowH + 2),
                         content: .reactions(ReactionsLayout(chips: chips, spoken: r.spoken, mineTap: mine)))
    }
}

final class ChatReactionsCell: ChatBaseCell {
    static let reuse = "reactions"
    private var chipViews: [UIView] = []
    private let tap = UIControl()
    private var hasMine = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        tap.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        contentView.addSubview(tap)
        isAccessibilityElement = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self, UITraitAccessibilityContrast.self]) { (cell: ChatReactionsCell, _) in
            for view in cell.chipViews { view.layer.borderColor = Self.edge.resolvedColor(with: cell.traitCollection).cgColor }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ row: ChatRow, layout: RowLayout) {
        super.configure(row, layout: layout)
        guard case .reactions(let l) = layout.content else { return }
        chipViews.forEach { $0.removeFromSuperview() }
        chipViews = l.chips.map { chip in
            let capsule = UIView(frame: chip.frame)
            capsule.backgroundColor = chip.mine ? ChatPalette.meBubble : ChatPalette.botBubble
            // Desktop Look: the bubbles are outlined boxes on the page, so the badge is one too (filled with the
            // bubble colour it was a chip the page's own colour, invisible in dark).
            capsule.layer.cornerRadius = Theme.isDesktop ? DesktopRows.radius : chip.frame.height / 2
            capsule.layer.borderWidth = Theme.isDesktop ? 1 : 1.5
            capsule.layer.borderColor = Self.edge.resolvedColor(with: traitCollection).cgColor
            capsule.isUserInteractionEnabled = false
            let label = UILabel(frame: capsule.bounds)
            label.attributedText = chip.text
            label.textAlignment = .center
            label.isAccessibilityElement = false
            capsule.addSubview(label)
            contentView.insertSubview(capsule, belowSubview: tap)
            return capsule
        }
        hasMine = l.mineTap != nil
        tap.frame = l.mineTap ?? .zero
        tap.isHidden = l.mineTap == nil
        accessibilityLabel = l.spoken
        accessibilityIdentifier = "chat.reactions"
        accessibilityTraits = .staticText
        accessibilityCustomActions = hasMine ? [UIAccessibilityCustomAction(name: "Remove Your Reaction") { [weak self] _ in
            self?.tapped()
            return true
        }] : nil
    }


    /// The badge's edge: the page's colour (a gap against the bubble), or in the Desktop Look the bubbles' outline.
    private static var edge: UIColor { Theme.isDesktop ? ChatPalette.strokeSecondary : ChatPalette.page }

    @objc private func tapped() { delegate?.chatCellRemoveReaction(rowId: rowId) }
}
