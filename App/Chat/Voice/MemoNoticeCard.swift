// The memo notice card (spec 1x-voice §3.7, V7): a native glass card at the top of the dock, never a 3 s toast — the
// owner couldn't read the errors that vanished. It says what happened in words and stays until closed, acted on, or
// its chat is left. Copy Details puts the title, message and detail on the pasteboard.

import UIKit

final class MemoNoticeCard: UIView {
    var onClose: (() -> Void)?
    var onAction: ((MemoNotice.Action) -> Void)?
    private(set) var notice: MemoNotice?

    private let glass: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        view.cornerConfiguration = .corners(radius: .fixed(20))
        return view
    }()
    private let glyph = UIImageView()
    private let titleLabel = UILabel()
    private let message = UITextView()
    private let detail = UILabel()
    private let actionButton = UIButton(type: .system)
    private let copyButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let buttons = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "memo.notice"
        addSubview(glass)
        glass.translatesAutoresizingMaskIntoConstraints = false

        glyph.contentMode = .center
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.textColor = ChatPalette.label
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityIdentifier = "memo.notice.title"

        // The message is selectable (the owner can copy any part of it), up to 4 lines.
        message.isEditable = false
        message.isSelectable = true
        message.isScrollEnabled = false
        message.backgroundColor = .clear
        message.textContainerInset = .zero
        message.textContainer.lineFragmentPadding = 0
        message.textContainer.maximumNumberOfLines = 4
        message.textContainer.lineBreakMode = .byTruncatingTail
        message.textColor = ChatPalette.label2
        message.accessibilityIdentifier = "memo.notice.message"
        detail.textColor = ChatPalette.label2
        detail.numberOfLines = 2

        actionButton.tintColor = ChatPalette.tint
        actionButton.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        actionButton.accessibilityIdentifier = "memo.notice.action"
        copyButton.setTitle("Copy Details", for: .normal)   // the Talk notice's word for the same thing
        copyButton.tintColor = ChatPalette.tint
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        copyButton.accessibilityIdentifier = "memo.notice.copy"
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)), for: .normal)
        closeButton.tintColor = ChatPalette.label2
        closeButton.accessibilityLabel = "Close"
        closeButton.accessibilityIdentifier = "memo.notice.close"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let header = UIStackView(arrangedSubviews: [glyph, titleLabel])
        header.axis = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        buttons.addArrangedSubview(actionButton)
        buttons.addArrangedSubview(copyButton)
        buttons.addArrangedSubview(UIView())
        buttons.axis = .horizontal
        buttons.spacing = 16
        buttons.alignment = .center
        let column = UIStackView(arrangedSubviews: [header, message, detail, buttons])
        column.axis = .vertical
        column.spacing = 4
        column.setCustomSpacing(2, after: header)
        column.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(column)
        glass.contentView.addSubview(closeButton)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            // 12 pt vertical and 14 pt horizontal padding (wrapping rows get 12–14 pt, owner feedback).
            column.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 12),
            column.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: 2),
            {
                let c = column.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -6)
                c.priority = .init(999)
                return c
            }(),
            closeButton.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 0),
            closeButton.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: 0),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            actionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            copyButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        // Never clipped: the glass draws its own edge and shadow past its bounds.
        clipsToBounds = false
        applyFonts()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: MemoNoticeCard, _) in
            view.applyFonts()
            if let notice = view.notice { view.show(notice) }   // the glyph follows the title's size
        }
    }

    /// Verify round 2: every line follows the text size (the title, message and buttons stayed at 15/13/15 pt while the
    /// detail grew, and at XXL the code line read larger than the explanation). Title and buttons Subheadline, message
    /// Footnote, the detail's code line one point under the message.
    private var titleFont: UIFont {
        UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: HQFont.system(ofSize: 15, weight: .semibold), maximumPointSize: 28,
                                                             compatibleWith: traitCollection)
    }

    private func applyFonts() {
        let t = traitCollection
        titleLabel.font = titleFont
        let messageFont = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: HQFont.system(ofSize: 13), maximumPointSize: 26, compatibleWith: t)
        message.font = messageFont
        let detailSize = min(HQFont.preferred(.caption1, compatibleWith: t).pointSize, messageFont.pointSize - 1)
        detail.font = HQFont.monoFace(ofSize: detailSize, weight: .regular)
        actionButton.titleLabel?.font = titleFont
        copyButton.titleLabel?.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: HQFont.system(ofSize: 15), maximumPointSize: 28,
                                                                                           compatibleWith: t)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ notice: MemoNotice) {
        self.notice = notice
        let symbol: String, color: UIColor
        switch notice.tone {
        case .warning: symbol = "exclamationmark.triangle.fill"; color = ChatPalette.orange
        case .error: symbol = "xmark.octagon.fill"; color = ChatPalette.red
        case .info: symbol = "info.circle.fill"; color = ChatPalette.tint
        }
        glyph.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: titleFont.pointSize, weight: .semibold))
        glyph.tintColor = color
        titleLabel.text = notice.title
        message.text = notice.message
        detail.text = notice.detail
        detail.isHidden = notice.detail == nil
        // A warning with nothing behind its words ("No Speech Detected") or a permission notice ("Microphone Access Is Off")
        // has nothing worth copying; an error always offers it.
        copyButton.isHidden = !notice.copies || (notice.detail == nil && notice.tone != .error)
        if let title = notice.actionTitle {
            actionButton.isHidden = false
            actionButton.setTitle(title, for: .normal)
        } else {
            actionButton.isHidden = true
        }
        buttons.isHidden = actionButton.isHidden && copyButton.isHidden
        accessibilityLabel = nil
    }

    var copyText: String {
        guard let notice else { return "" }
        return [notice.title, notice.message, notice.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    @objc private func copyTapped() {
        VoiceClipboard.copy(copyText)   // [talk] the probe reads what was copied
        Haptics.play(.success)
        CopyFeedback.flash(copyButton, title: "Copy Details")
    }

    @objc private func closeTapped() { onClose?() }

    @objc private func actionTapped() {
        guard let action = notice?.action else { return }
        onAction?(action)
    }
}
