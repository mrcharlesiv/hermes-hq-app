import UIKit

nonisolated enum PhoneChatCardContent {
    case proposal(PhoneProposal)
    case result(PhoneResultCard)

    var title: String {
        switch self {
        case .proposal(let call): call.name ?? "Call " + phoneShown(call.to)
        case .result(let call): call.title
        }
    }

    var detail: String {
        switch self {
        case .proposal(let call): (call.name == nil ? "" : phoneShown(call.to) + "\n") + call.goal
        case .result(let call): call.subtitle
        }
    }

    var isProposal: Bool {
        if case .proposal = self { return true }
        return false
    }

    var mark: PhoneMark {
        switch self {
        case .proposal: .proposal
        case .result(let call): call.mark
        }
    }

    var spoken: String {
        switch self {
        case .proposal(let call): call.spokenReview
        case .result: "\(title). \(detail)"
        }
    }
}

nonisolated enum PhoneChatCardLayout {
    static let inset: CGFloat = 14
    static let icon: CGFloat = 38
    static let gap: CGFloat = 12

    static func titleFont(_ style: ChatStyle) -> UIFont { HQFont.style(.body, weight: .semibold, category: style.category) }
    static func detailFont(_ style: ChatStyle) -> UIFont {
        HQFont.scaled(14, like: .subheadline, category: style.category)
    }
    static func reviewWidth(_ style: ChatStyle) -> CGFloat {
        ceil(("Review" as NSString).size(withAttributes: [.font: titleFont(style)]).width) + 24
    }

    static func stacks(_ card: PhoneChatCardContent, width: CGFloat, style: ChatStyle) -> Bool {
        card.isProposal && width - reviewWidth(style) < 220
    }

    static func wordsWidth(_ card: PhoneChatCardContent, width: CGFloat, style: ChatStyle) -> CGFloat {
        let trailing = card.isProposal ? (stacks(card, width: width, style: style) ? 0 : reviewWidth(style) + gap) : 18 + gap
        return max(1, width - 2 * inset - icon - gap - trailing)
    }

    static func wordHeights(_ card: PhoneChatCardContent, width: CGFloat, style: ChatStyle) -> (CGFloat, CGFloat) {
        let w = wordsWidth(card, width: width, style: style)
        func measure(_ text: String, _ font: UIFont, _ lines: Int) -> CGFloat {
            let size = CGSize(width: w, height: .greatestFiniteMagnitude)
            let bounds = (text as NSString).boundingRect(with: size, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                         attributes: [.font: font], context: nil)
            return min(ceil(bounds.height), ceil(font.lineHeight) * CGFloat(lines))
        }
        return (measure(card.title, titleFont(style), 2), measure(card.detail, detailFont(style), card.isProposal ? 4 : 2))
    }

    static func height(for card: PhoneChatCardContent, width: CGFloat, style: ChatStyle) -> CGFloat {
        let (title, detail) = wordHeights(card, width: width, style: style)
        let stacked = stacks(card, width: width, style: style)
        return 2 * inset + max(icon, title + 3 + detail, card.isProposal && !stacked ? 44 : 0) + (stacked ? 50 : 0)
    }
}

final class PhoneChatCardControl: UIButton {
    private let icon = UIImageView()
    private let headlineLabel = UILabel()
    private let detailLabel = UILabel()
    private let review = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    private var card: PhoneChatCardContent?
    private var style: ChatStyle?
    var open: (() -> Void)?

    init() {
        super.init(frame: .zero)
        for view in [icon, headlineLabel, detailLabel, review, chevron] {
            view.isAccessibilityElement = false
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        headlineLabel.numberOfLines = 2
        headlineLabel.lineBreakMode = .byTruncatingTail
        detailLabel.lineBreakMode = .byTruncatingTail
        icon.contentMode = .center
        chevron.contentMode = .center
        review.textAlignment = .center
        review.text = "Review"
        isAccessibilityElement = true
        accessibilityTraits = .button
        addAction(UIAction { [weak self] _ in self?.open?() }, for: .primaryActionTriggered)
        #if targetEnvironment(macCatalyst)
        PointerEffects.surface(self)
        #endif
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: PhoneChatCardControl, _) in
            view.styleCard()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func styleCard() {
        backgroundColor = ChatPalette.promptCard
        layer.cornerRadius = HQShape.radius(18, .card)
        layer.cornerCurve = .continuous
        let edge = ChatPalette.promptEdge.resolvedColor(with: traitCollection)
        layer.borderColor = edge.cgColor
        layer.borderWidth = edge.cgColor.alpha > 0 ? max(HQShape.pixel(traitCollection.displayScale), 1) : 0
    }

    override var isHighlighted: Bool { didSet { alpha = PointerEffects.dim(isHighlighted, to: 0.72) } }

    func configure(_ card: PhoneChatCardContent, style: ChatStyle) {
        self.card = card
        self.style = style
        styleCard()
        headlineLabel.font = PhoneChatCardLayout.titleFont(style)
        headlineLabel.textColor = ChatPalette.label
        headlineLabel.text = card.title
        detailLabel.font = PhoneChatCardLayout.detailFont(style)
        detailLabel.textColor = ChatPalette.label2
        detailLabel.numberOfLines = card.isProposal ? 4 : 2
        detailLabel.text = card.detail
        icon.backgroundColor = card.mark.uiColor
        icon.tintColor = PhoneCardColors.ink(on: card.mark.uiColor, minimum: 3)
        icon.layer.cornerRadius = PhoneChatCardLayout.icon / 2
        icon.image = UIImage(systemName: card.mark.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        chevron.tintColor = ChatPalette.label2
        chevron.isHidden = card.isProposal
        review.isHidden = !card.isProposal
        review.font = PhoneChatCardLayout.titleFont(style)
        review.textColor = PhoneCardColors.onAccent
        review.backgroundColor = ChatPalette.tint
        review.layer.cornerRadius = HQShape.radius(16, .card)
        review.clipsToBounds = true
        accessibilityLabel = card.spoken
        accessibilityIdentifier = card.isProposal ? "phone.chat.proposal" : "phone.chat.result"
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let card, let style else { return }
        let inset = PhoneChatCardLayout.inset
        let iconSize = PhoneChatCardLayout.icon
        let gap = PhoneChatCardLayout.gap
        let stacked = PhoneChatCardLayout.stacks(card, width: bounds.width, style: style)
        let middle = (bounds.height - (stacked ? 50 : 0)) / 2
        let x = inset + iconSize + gap
        let width = PhoneChatCardLayout.wordsWidth(card, width: bounds.width, style: style)
        let (title, detail) = PhoneChatCardLayout.wordHeights(card, width: bounds.width, style: style)
        let y = middle - (title + 3 + detail) / 2
        icon.frame = CGRect(x: inset, y: middle - iconSize / 2, width: iconSize, height: iconSize)
        headlineLabel.frame = CGRect(x: x, y: y, width: width, height: title)
        detailLabel.frame = CGRect(x: x, y: y + title + 3, width: width, height: detail)
        let reviewWidth = PhoneChatCardLayout.reviewWidth(style)
        review.frame = CGRect(x: bounds.width - inset - reviewWidth, y: stacked ? bounds.height - inset - 44 : middle - 22,
                              width: reviewWidth, height: 44)
        chevron.frame = CGRect(x: bounds.width - inset - 18, y: middle - 10, width: 18, height: 20)
    }
}

extension PhoneMark {
    var uiColor: UIColor {
        switch self {
        case .phone, .success: ChatPalette.green
        case .warning, .voicemail, .missed: PhoneCardColors.attention
        case .failed: ChatPalette.red
        case .proposal: ChatPalette.tint
        case .ended: ChatPalette.label2
        }
    }
}

final class PhoneResultCell: ChatBaseCell {
    static let reuse = "PhoneResultCell"
    private let card = PhoneChatCardControl()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        contentView.addSubview(card)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ row: ChatRow, layout: RowLayout) {
        super.configure(row, layout: layout)
        guard case .phoneResult(let result, let date) = row.kind, case .phoneResult(let frame) = layout.content else { return }
        card.frame = frame
        card.configure(.result(result), style: ChatStyleCache.shared.style(for: traitCollection.preferredContentSizeCategory))
        card.open = { [weak self] in self?.delegate?.chatCellOpenPhoneResult(result, sentAt: date) }
    }
}


enum PhoneCardColors {
    /// The fill that says "needs you" or "did not connect" (owner-approved drawings: a bright orange). The theme's
    /// orange is an ink: in a light appearance it is a dark red-orange made to be read as words on white, which as a
    /// fill reads as red, the colour of Hang up. So a light appearance fills with the bright orange and a dark one
    /// keeps the theme's, which is bright already. Words still use the theme's orange.
    static let attention = UIColor { @Sendable traits in
        traits.userInterfaceStyle == .dark ? ChatPalette.orange.resolvedColor(with: traits)
            : UIColor(red: 1, green: 0.584, blue: 0, alpha: 1)
    }
    static let onAccent = ink(on: HQPalette.tint)
    static let onRed = ink(on: HQPalette.red)

    /// Preserve the skin's ink when it reads against the fill. Bright fills may need darker ink.
    static func ink(on fill: UIColor, minimum: Double = 4.5) -> UIColor {
        let preferred = HQPalette.onTint
        return UIColor { @Sendable traits in
            func rgba(_ color: UIColor) -> RGBA? {
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                guard color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
                return RGBA(unit: Double(red), Double(green), Double(blue), Double(alpha))
            }
            guard let ground = rgba(fill), let ink = rgba(preferred), ink.contrast(with: ground) < minimum else {
                return preferred.resolvedColor(with: traits)
            }
            return RGBA.black.contrast(with: ground) > RGBA.white.contrast(with: ground) ? RGBA.black.uiColor : RGBA.white.uiColor
        }
    }
}
