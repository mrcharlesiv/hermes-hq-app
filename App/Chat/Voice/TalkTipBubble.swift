// [talk] The Talk tip (docs/spec/3x-talk.md §5.1) as a glass card in the chat's own view, above the circle it names.
// Not a popover. A popover that shows by itself takes the next touch anywhere outside it (Back, a memo's play disc, a
// notice's Close) and makes the screen refuse every sheet while it is up: the voice memo UI suite caught exactly that.
// The web's tip takes nothing either (`W:src/ui-kit/tip.tsx`): it stays until it is closed or Talk is tapped, and
// everything around it keeps working. The transcript's end makes room for it (`W:src/ui-voice/voice-extras.tsx`,
// `makeRoomForTip`), so it never covers the newest message.
// The two voice memo tips (spec 1x-voice §3.7) are the same card with the mic glyph: as popovers they swallowed the
// next tap the same way (UX study 2026-10-19).

import UIKit

final class TalkTipBubble: UIView {
    let tip: MemoTip
    var onClose: (() -> Void)?

    private let glass: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        view.cornerConfiguration = .corners(radius: .fixed(22))
        return view
    }()
    /// Glyph, words, Close in a row; at accessibility sizes glyph and Close on the top line, the words under them at
    /// full width (beside the glyph they were a narrow, hyphenated column at AX5).
    private let outer = UIStackView()
    private let row = UIStackView()
    private let glyph: UIImageView
    private let words = UIStackView()
    private let close: UIButton
    private let gap = UIView()
    private let title = UILabel()
    private let message = UILabel()
    private var measured: (width: CGFloat, limit: CGFloat, category: UIContentSizeCategory, height: CGFloat)?

    /// What VoiceOver hears when the card appears.
    private(set) var spoken = ""

    init(tip: MemoTip, name: String) {
        self.tip = tip
        glyph = UIImageView(image: UIImage(systemName: tip == .talk ? "waveform" : "mic",
                                           withConfiguration: UIImage.SymbolConfiguration(textStyle: .title3)))
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        config.baseForegroundColor = ChatPalette.label2
        close = UIButton(configuration: config)
        super.init(frame: .zero)
        close.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .primaryActionTriggered)
        accessibilityIdentifier = "memo.tip"
        if tip == .talk { MemoTips.talkName = name }
        addSubview(glass)
        glyph.tintColor = ChatPalette.tint
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.setContentCompressionResistancePriority(.required, for: .horizontal)
        // Capped: at AX5 the uncapped words grew the card over the whole chat and under the top bar.
        title.font = Self.subheadline(.semibold, max: 26)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = ChatPalette.label
        title.text = MemoTips.title(tip)
        title.numberOfLines = 0
        message.font = Self.subheadline(.regular, max: 24)
        message.adjustsFontForContentSizeCategory = true
        message.textColor = ChatPalette.label2
        message.text = MemoTips.message(tip)
        message.numberOfLines = 0
        message.lineBreakMode = .byTruncatingTail
        words.addArrangedSubview(title)
        words.addArrangedSubview(message)
        words.axis = .vertical
        words.spacing = 2
        close.accessibilityLabel = tip == .talk ? "Close Talk tip" : "Close tip"
        close.accessibilityIdentifier = "memo.tip.close"
        close.widthAnchor.constraint(equalToConstant: 44).isActive = true
        spoken = "\(title.text ?? ""). \(message.text ?? "")"
        if DeviceWord.isMac {
            // [mac] Stress test 2026-10-28 #12 / #69: the card took up to five lines (a quarter of the chat) with the
            // glyph centred on all of them. On the Mac it is one run of words, title first, at most two lines, and the
            // glyph and Close sit on its first line.
            let line = ceil(message.font.lineHeight)
            message.attributedText = Self.macWords(title: title, message: message)
            title.isHidden = true
            glyph.contentMode = .center
            glyph.heightAnchor.constraint(equalToConstant: line).isActive = true
            close.heightAnchor.constraint(equalToConstant: line).isActive = true
            row.alignment = .top
        } else {
            close.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            row.alignment = .center
        }
        gap.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.axis = .horizontal
        row.spacing = 10
        outer.axis = .vertical
        outer.spacing = 2
        outer.addArrangedSubview(row)
        outer.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(outer)
        arrange()
        // The bottom edge gives way while the card is laid out at zero height (before its first frame).
        let bottom = outer.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -Self.pad)
        bottom.priority = .init(999)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: Self.pad),   // a wrapping row: 12 pt above and below
            bottom,
            outer.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 14),
            outer.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -4),
        ])
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (bubble: TalkTipBubble, _) in bubble.arrange() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Above and below the words: 12 pt; [mac] 9 on the Mac's shorter card (#12).
    private static var pad: CGFloat { DeviceWord.isMac ? 9 : 12 }

    /// The look's Subheadline: 15 pt in the iOS look, 13.5 in the Desktop Look (Mac polish #83: it was 15 there too, as
    /// big as a reply).
    private static func subheadline(_ weight: UIFont.Weight, max: CGFloat) -> UIFont {
        let size = ThemeTable.current.state.desktopLook ? HQFont.desktopSpec(.subheadline).size : 15
        return UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: HQFont.system(ofSize: size, weight: weight), maximumPointSize: max)
    }

    /// [mac] Stress test 2026-10-28 #12: the title in its own weight and colour, then the message, in one label.
    private static func macWords(title: UILabel, message: UILabel) -> NSAttributedString {
        let words = NSMutableAttributedString(string: (title.text ?? "") + "  ",
                                              attributes: [.font: title.font as Any, .foregroundColor: title.textColor as Any])
        words.append(NSAttributedString(string: message.text ?? "",
                                        attributes: [.font: message.font as Any, .foregroundColor: message.textColor as Any]))
        return words
    }

    private var stacked: Bool { traitCollection.preferredContentSizeCategory.isAccessibilityCategory }

    private func arrange() {
        let parts: [UIView] = stacked ? [glyph, gap, close] : [glyph, words, close]
        guard row.arrangedSubviews != parts else { return }
        for view in row.arrangedSubviews { row.removeArrangedSubview(view); view.removeFromSuperview() }
        for view in parts { row.addArrangedSubview(view) }
        if stacked {
            outer.addArrangedSubview(words)
        }
        measured = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if glass.frame != bounds { glass.frame = bounds }
    }

    /// The card's height at `width`, for the text size in use, never over `limit`: a message that would run past it
    /// ends with "…" (VoiceOver still reads it whole). Measured once per width, limit and size.
    func height(for width: CGFloat, limit: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
        let category = traitCollection.preferredContentSizeCategory
        if let measured, measured.width == width, measured.limit == limit, measured.category == category { return measured.height }
        func measure() -> CGFloat {
            let size = outer.systemLayoutSizeFitting(CGSize(width: max(1, width - 18), height: UIView.layoutFittingCompressedSize.height),
                                                     withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
            return ceil(size.height) + 2 * Self.pad
        }
        // [mac] Stress test 2026-10-28 #12: two lines at most on the Mac; the rest ends with "…". Round 2: three, so a narrow
        // window keeps the whole tip (it ended "Click and hold the…").
        let most = DeviceWord.isMac ? 3 : 6
        message.numberOfLines = DeviceWord.isMac ? most : 0
        var height = measure()
        var lines = most
        while height > limit, lines >= 1 {
            message.numberOfLines = lines
            height = measure()
            lines -= 1
        }
        height = min(height, limit)
        measured = (width, limit, category, height)
        return height
    }
}
