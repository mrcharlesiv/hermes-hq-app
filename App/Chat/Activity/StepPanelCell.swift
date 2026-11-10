import UIKit

/// [inspector] A step in the Mac's right panel (`InspectorLook`): one flat row, not the sheet's card on a rail. The
/// step's emoji · its words on one line with its code's first line under them in grey monospace · its time at the
/// trailing edge (the braille spinner while it runs, "Failed" in red). The table rules between rows; a click opens the
/// step, as the sheet's card does.
final class StepPanelCell: UITableViewCell {
    private let emoji = UILabel()
    private let text = UILabel()
    private let detail = UILabel()
    private let meta = UILabel()
    private let spinner = GlyphSpinner(style: .braille, color: ChatPalette.label2, size: HQFont.symbolSize(15, like: .subheadline, cap: 24))

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        emoji.font = InspectorLook.textFont
        emoji.textAlignment = .center
        text.font = InspectorLook.textFont
        text.textColor = ChatPalette.label
        text.lineBreakMode = .byTruncatingTail
        detail.font = HQFont.monoFace(ofSize: InspectorLook.detailFont.pointSize)
        detail.textColor = ChatPalette.label2
        detail.lineBreakMode = .byTruncatingMiddle
        meta.font = InspectorLook.detailFont
        meta.textColor = ChatPalette.label2
        for view in [meta, spinner] as [UIView] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let words = UIStackView(arrangedSubviews: [text, detail])
        words.axis = .vertical
        words.spacing = 1
        let row = UIStackView(arrangedSubviews: [emoji, words, meta, spinner])
        row.alignment = .firstBaseline
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            emoji.widthAnchor.constraint(equalToConstant: HQFont.scaled(18)),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: InspectorLook.margin),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -InspectorLook.margin),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ call: ToolCall) {
        let line = ToolLines.line(call)
        let failed = call.state == .failed, running = call.state == .running
        emoji.text = line.emoji
        // The sheet's words (`StepLineCell.configure`).
        let plain = failed ? nil : ToolWords.plainLabel(name: call.name, args: ChatRunSummary.args(call), preview: call.title)
        text.text = plain ?? (call.name == "terminal" && line.text == "terminal" ? "Running a command" : line.text)
        let code = line.code.flatMap { StepLineCell.codePreview($0).lines.first }?.trimmingCharacters(in: .whitespaces)
        detail.text = code
        detail.isHidden = code?.isEmpty != false
        let time = call.durationSeconds.map(ToolCards.formatDurationSeconds)
        meta.text = failed ? "Failed" : time
        meta.textColor = failed ? ChatPalette.red : ChatPalette.label2
        meta.isHidden = running || meta.text?.isEmpty != false
        spinner.isHidden = !running
        accessibilityLabel = [text.text, line.code, failed ? "Failed" : nil, running ? "running" : time]
            .compactMap { $0 }.joined(separator: ", ")
        accessibilityTraits = .button
    }
}
