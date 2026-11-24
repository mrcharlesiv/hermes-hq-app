import UIKit

/// [threads] A thread open in place (docs/spec/3x-threads.md §5): its header, a thin line in the bot's colour, and
/// what it shows drawn by the chat's own cells standing inside this one (as the send lift's stand-in does,
/// `ChatBubbleCell.liftStandIn`), so a thread's words look exactly like the chat's. The whole row is one button: it
/// opens the thread's own chat.
final class ChatThreadCell: ChatBaseCell {
    static let reuse = "thread"

    private let press = UIControl()
    private let glyph = CAShapeLayer()
    private let nameLabel = UILabel()
    private let tailLabel = UILabel()
    private let chevron = UIImageView()
    private let line = UIView()
    /// The stand-ins, kept between configures (a streaming reply reconfigures many times a second).
    private var bubbles: [ChatBubbleCell] = []
    private var waiting: [ChatWaitingCell] = []
    private var key = ""

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        glyph.fillColor = UIColor.clear.cgColor
        glyph.lineWidth = ChatGlyph.thread.lineWidth
        glyph.lineCap = .round
        glyph.lineJoin = .round
        contentView.layer.addSublayer(glyph)
        nameLabel.adjustsFontForContentSizeCategory = true
        tailLabel.adjustsFontForContentSizeCategory = true
        tailLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(nameLabel)
        contentView.addSubview(tailLabel)
        chevron.contentMode = .center
        contentView.addSubview(chevron)
        line.layer.cornerRadius = ThreadRows.lineWidth / 2
        line.isUserInteractionEnabled = false
        contentView.addSubview(line)
        // Over everything: a thread's bubbles are read here and acted on in the thread itself.
        press.addTarget(self, action: #selector(open), for: .touchUpInside)
        press.addTarget(self, action: #selector(pressDown), for: [.touchDown, .touchDragEnter])
        press.addTarget(self, action: #selector(pressUp), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        contentView.addSubview(press)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "Opens the thread"
        // The look and the theme: its colours follow both.
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (cell: ChatThreadCell, _: UITraitCollection) in cell.recolor() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var tint: ThreadTint = .label2
    private var problem = false

    private func recolor() {
        glyph.strokeColor = ChatPalette.label2.resolvedColor(with: traitCollection).cgColor
        nameLabel.textColor = ChatPalette.label2
        tailLabel.textColor = problem ? .systemRed : ChatPalette.label3
        chevron.tintColor = ChatPalette.label3
        switch tint {
        case .accent(let red, let green, let blue): line.backgroundColor = UIColor(red: red, green: green, blue: blue, alpha: 1)
        case .label: line.backgroundColor = ChatPalette.label
        case .label2: line.backgroundColor = ChatPalette.label2
        }
    }

    override func configure(_ row: ChatRow, layout: RowLayout) {
        rowId = row.id
        guard case .thread(let thread) = row.kind, case .thread(let frames) = layout.content else { return }
        key = thread.key
        tint = thread.tint
        problem = thread.problem
        let width = bounds.width > 0 ? bounds.width : (superview?.bounds.width ?? 0)

        // Header: the mark, the name, " · 6 messages", and the caret at the trailing edge.
        let base = UIFontMetrics(forTextStyle: .footnote)
        nameLabel.font = base.scaledFont(for: HQFont.system(ofSize: 13, weight: .semibold))
        tailLabel.font = base.scaledFont(for: HQFont.system(ofSize: 13, weight: .regular))
        nameLabel.text = thread.name
        tailLabel.text = thread.tail.map { "· \($0)" }
        tailLabel.isHidden = thread.tail == nil
        let side = min(frames.header.height - 2, max(15, ceil(nameLabel.font.pointSize * 1.15)))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.path = ChatGlyph.thread.path(size: side)
        glyph.frame = CGRect(x: frames.header.minX, y: frames.header.midY - side / 2, width: side, height: side)
        CATransaction.commit()
        let caret: CGFloat = 12
        chevron.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        chevron.frame = CGRect(x: frames.header.maxX - caret, y: frames.header.minY, width: caret, height: frames.header.height)
        let textX = glyph.frame.maxX + 5
        let room = max(0, chevron.frame.minX - 8 - textX)
        let nameWidth = min(room, ceil(nameLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: frames.header.height)).width))
        nameLabel.frame = CGRect(x: textX, y: frames.header.minY, width: nameWidth, height: frames.header.height)
        tailLabel.frame = CGRect(x: nameLabel.frame.maxX + 5, y: frames.header.minY,
                                 width: max(0, room - nameWidth - 5), height: frames.header.height)
        line.frame = frames.line

        // What the thread shows: the chat's own cells, standing inside this one.
        var usedBubbles = 0, usedWaiting = 0
        for inner in frames.inner {
            let cell: ChatBaseCell
            switch inner.row.kind {
            case .bubble:
                if usedBubbles == bubbles.count { bubbles.append(standIn(ChatBubbleCell(style: .default, reuseIdentifier: nil))) }
                cell = bubbles[usedBubbles]; usedBubbles += 1
            case .waiting:
                if usedWaiting == waiting.count { waiting.append(standIn(ChatWaitingCell(style: .default, reuseIdentifier: nil))) }
                cell = waiting[usedWaiting]; usedWaiting += 1
            default:
                continue
            }
            cell.isHidden = false
            cell.frame = inner.frame
            cell.layoutIfNeeded()
            cell.contentView.frame = cell.bounds
            cell.configure(inner.row, layout: inner.layout)
        }
        for cell in bubbles[usedBubbles...] { cell.isHidden = true }
        for cell in waiting[usedWaiting...] { cell.isHidden = true }
        press.frame = CGRect(x: 0, y: 0, width: width, height: layout.height)
        contentView.bringSubviewToFront(press)
        recolor()
        accessibilityLabel = [thread.name, thread.tail].compactMap { $0 }.joined(separator: ", ")
        accessibilityIdentifier = "chat.thread"
    }

    /// A chat cell made to stand inside this one: upright (this cell's content is already turned the right way up),
    /// and silent (the row is the button).
    private func standIn<Cell: ChatBaseCell>(_ cell: Cell) -> Cell {
        cell.contentView.transform = .identity
        cell.isUserInteractionEnabled = false
        cell.isAccessibilityElement = false
        cell.accessibilityElementsHidden = true
        contentView.insertSubview(cell, belowSubview: press)
        return cell
    }

    @objc private func open() {
        Haptics.play(.selection)
        delegate?.chatCellOpenThread(key: key)
    }

    @objc private func pressDown() { contentView.alpha = 0.6 }
    @objc private func pressUp() {
        UIView.animate(withDuration: HQMotion.fade) { self.contentView.alpha = 1 }   // motion-ok: opacity only
    }

    override func accessibilityActivate() -> Bool {
        delegate?.chatCellOpenThread(key: key)
        return true
    }
}
