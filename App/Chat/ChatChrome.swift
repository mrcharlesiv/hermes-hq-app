import UIKit

/// Jump to latest (spec 06 §4.4): a 44 pt interactive glass circle with a down chevron. The spec shows no count and
/// no dot (the owner rejected unread numbers); `showsCount` exists for the brief's optional count, off by default.
final class JumpButton: UIView {
    static var showsCount = false
    var onTap: (() -> Void)?
    private let glass: UIVisualEffectView = {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        let view = UIVisualEffectView(effect: effect)
        view.cornerConfiguration = .capsule()
        return view
    }()
    private let chevron = UIImageView()
    private let countLabel = UILabel()
    private(set) var isShown = false
    /// L422: "Approval needed", a tinted glass capsule, while an approval waits out of sight. `onSizeChange` asks the
    /// screen to resize it.
    private(set) var approvalMode = false
    var onSizeChange: (() -> Void)?
    private let approvalLabel = UILabel()

    /// The width the button wants now: a circle, or a capsule around the words.
    var preferredWidth: CGFloat {
        guard approvalMode else { return ChatMetrics.jumpSize }
        // [desktop-frost] The look's flat capsule around the words; off the look, the glass capsule.
        if desktop { return max(ChatMetrics.jumpSize, ceil(flatLabel.intrinsicContentSize.width) + 24) }
        return ceil(approvalLabel.intrinsicContentSize.width) + 32
    }

    // [desktop-frost] The Desktop Look's jump (owner, build 321): a small flat round button where the iOS look's sits,
    // sized like a desktop icon button (36 pt circle in the 44 pt tap area), a hairline border, the composer's fill over
    // a light blur (no Liquid Glass), a down arrow. An approval waiting out of sight widens it into a flat capsule of the
    // same fill with an accent border and "Approval needed" in the accent (no glass, no count). Look off: the glass
    // circle.
    static let desktopDiameter: CGFloat = 36
    /// The tap area (the whole button) holding the circle.
    private let flat = UIView()
    private let circle = DesktopFrostView()
    private let flatArrow = UIImageView()
    /// "Approval needed" inside the look's flat capsule.
    private let flatLabel = UILabel()
    private(set) var desktop = false

    /// The look's round button, or the glass circle again.
    func applyLook() {
        desktop = Theme.isDesktop
        glass.isHidden = desktop
        flat.isHidden = !desktop
        countLabel.alpha = desktop ? 0 : 1
        if desktop {
            let accent = approvalMode
            circle.color = ChatPalette.editor
            circle.tintAlpha = 0.88
            circle.layer.borderWidth = accent ? 1.5 : HQShape.hairline
            circle.layer.borderColor = (accent ? ChatPalette.tint : ChatPalette.strokeSecondary).resolvedColor(with: traitCollection).cgColor
            flatArrow.image = UIImage(systemName: "arrow.down",
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
            flatArrow.tintColor = accent ? ChatPalette.tint : ChatPalette.label2
            flatArrow.isHidden = accent
            flatLabel.isHidden = !accent
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// The tap area's height: 44 pt in both looks.
    var preferredHeight: CGFloat { ChatMetrics.jumpSize }

    /// The look's circle, in the button's coordinates (tests).
    var flatCircleFrame: CGRect { circle.frame }

    func setApproval(_ on: Bool) {
        guard on != approvalMode else { return }
        approvalMode = on
        defer { if desktop { applyLook(); onSizeChange?() } }   // [desktop-frost] the round button's accent
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        if on { effect.tintColor = ChatPalette.tint }
        glass.effect = effect
        approvalLabel.isHidden = !on
        chevron.isHidden = on
        isAccessibilityElement = true
        accessibilityLabel = on ? "Approval needed" : "Jump to Latest"
        accessibilityHint = on ? "Scrolls to the request." : nil
        accessibilityIdentifier = on ? "jump.approval" : "chat.jump"
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        onSizeChange?()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(glass)
        // An 18 pt down arrow (spec 06 §4.4).
        chevron.image = UIImage(systemName: "arrow.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
        chevron.tintColor = ChatPalette.label2
        chevron.contentMode = .center
        glass.contentView.addSubview(chevron)
        approvalLabel.text = "Approval needed"
        approvalLabel.font = HQFont.preferred(.subheadline).withSize(min(HQFont.preferred(.subheadline).pointSize, 20))
        approvalLabel.adjustsFontForContentSizeCategory = true
        approvalLabel.textColor = ChatPalette.onTint
        approvalLabel.textAlignment = .center
        approvalLabel.isHidden = true
        glass.contentView.addSubview(approvalLabel)
        flatLabel.text = "Approval needed"
        flatLabel.font = approvalLabel.font
        flatLabel.adjustsFontForContentSizeCategory = true
        flatLabel.textColor = ChatPalette.tint
        flatLabel.textAlignment = .center
        flatLabel.isHidden = true
        countLabel.font = HQFont.digits(12, weight: .semibold, like: .caption1, cap: 18)
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textColor = ChatPalette.onTint
        countLabel.backgroundColor = ChatPalette.tint
        countLabel.textAlignment = .center
        countLabel.layer.cornerRadius = 9
        countLabel.layer.masksToBounds = true
        countLabel.isHidden = true
        addSubview(countLabel)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        glass.addGestureRecognizer(tap)
        flat.isHidden = true
        circle.isUserInteractionEnabled = false
        circle.layer.masksToBounds = true
        flatArrow.contentMode = .center
        circle.addSubview(flatArrow)
        circle.addSubview(flatLabel)
        flat.addSubview(circle)
        flat.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addSubview(flat)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Jump to Latest"
        accessibilityIdentifier = "chat.jump"
        alpha = 0
        isHidden = true
        // The words grow with the text size (to their cap), so the capsule asks to be resized with them.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: JumpButton, _) in
            guard view.approvalMode else { return }
            view.invalidateIntrinsicContentSize()
            view.setNeedsLayout()
            view.onSizeChange?()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: preferredWidth, height: preferredHeight) }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        if desktop {
            flat.frame = bounds
            let d = min(Self.desktopDiameter, bounds.width, bounds.height)
            // The plain jump is the 36 pt circle; an approval, a capsule as wide as the tap area.
            let w = approvalMode ? max(d, bounds.width - (ChatMetrics.jumpSize - d)) : d
            circle.frame = CGRect(x: (bounds.width - w) / 2, y: (bounds.height - d) / 2, width: w, height: d)
            circle.layer.cornerRadius = d / 2
            flatArrow.frame = circle.bounds
            flatLabel.frame = circle.bounds.insetBy(dx: 8, dy: 0)
        }
        chevron.frame = glass.contentView.bounds
        approvalLabel.frame = glass.contentView.bounds
        // [a11y] The count's text grows with the text size (to 18 pt), so its pill grows with it.
        let h = max(18, ceil(countLabel.font.lineHeight) + 2)
        let w = max(h, countLabel.intrinsicContentSize.width + 10)
        countLabel.frame = CGRect(x: (bounds.width - w) / 2, y: -h / 2, width: w, height: h)
        countLabel.layer.cornerRadius = h / 2
    }

    func setCount(_ count: Int) {
        countLabel.isHidden = !Self.showsCount || count <= 0
        countLabel.text = count > 99 ? "99+" : "\(count)"
        setNeedsLayout()
    }

    /// The desktop's `thread-jump-in` / `-out` (V:styles.css:2498): it arrives from 0.3 rem lower at 1.1× and settles
    /// to 1 over 200 ms on cubic-bezier(0.22, 1, 0.36, 1); it leaves 0.3 rem lower at 0.9× over 180 ms ease-in, always
    /// shrinking the way it travels. Reduce Motion: a 120 ms linear fade either way.
    private static let drop: CGFloat = 4.8
    private static func away(_ scale: CGFloat) -> CGAffineTransform { CGAffineTransform(translationX: 0, y: drop).scaledBy(x: scale, y: scale) }

    func setShown(_ shown: Bool, animated: Bool = true) {
        guard shown != isShown else { return }
        isShown = shown
        if shown {
            isHidden = false
            if animated && !HQMotion.reduced {
                transform = Self.away(1.1)
                let curve = UICubicTimingParameters(controlPoint1: CGPoint(x: 0.22, y: 1), controlPoint2: CGPoint(x: 0.36, y: 1))
                let animator = UIViewPropertyAnimator(duration: 0.2, timingParameters: curve)
                animator.addAnimations { self.alpha = 1; self.transform = .identity }
                animator.startAnimation()
            } else if animated {
                transform = .identity
                UIView.animate(withDuration: 0.12, delay: 0, options: [.curveLinear, .beginFromCurrentState]) { self.alpha = 1 }   // motion-ok: Reduce Motion's fade
            } else {
                alpha = 1; transform = .identity
            }
        } else {
            let done = { [weak self] in guard let self, !self.isShown else { return }; self.isHidden = true }
            if animated {
                let moves = !HQMotion.reduced   // under Reduce Motion it only fades
                UIView.animate(withDuration: moves ? 0.18 : 0.12, delay: 0, options: [moves ? .curveEaseIn : .curveLinear, .beginFromCurrentState]) {
                    self.alpha = 0
                    if moves { self.transform = Self.away(0.9) }
                } completion: { _ in done() }
            } else {
                alpha = 0
                done()
            }
        }
    }

    @objc private func tapped() { onTap?() }

    override func accessibilityActivate() -> Bool { onTap?(); return true }
}

/// The title in the bar (spec 06 §4.1): a glass rounded rectangle (r 14, 44 pt tall) holding the head (left of the
/// name, added at integration through `accessory`) and the name in 17 semibold (capped at 22).
final class ChatTitleView: UIView {
    var onTap: (() -> Void)?
    /// [Mac UI check 2026-11-13] V24: what a click on the title opens, shown when the pointer rests on it (the Mac's
    /// sidebar buttons say theirs). Its words keep the window's own tip from naming it.
    var tip: String? {
        didSet {
            guard tip != oldValue else { return }
            if let tipInteraction { removeInteraction(tipInteraction) }
            tipInteraction = tip.map { UIToolTipInteraction(defaultToolTip: $0) }
            if let tipInteraction { addInteraction(tipInteraction) }
        }
    }
    private var tipInteraction: UIToolTipInteraction?
    private let glass: UIVisualEffectView = {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        let view = UIVisualEffectView(effect: effect)
        view.cornerConfiguration = .corners(radius: .fixed(14))
        return view
    }()
    private let nameLabel = UILabel()
    /// The bot's name under a session's title (spec 06 §4.1: any session that isn't the bot's own chat), 13 pt capped
    /// at 18, label-2.
    private let subtitleLabel = UILabel()
    var subtitle: String? {
        didSet {
            guard subtitle != oldValue else { return }
            subtitleLabel.text = subtitle
            subtitleLabel.isHidden = subtitle == nil
            if (subtitle == nil) != (oldValue == nil) { updateFont() }   // [ui-sizing] the pair's fit
            updateLabel()
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }
    var accessory: UIView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let accessory { glass.contentView.addSubview(accessory) }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }
    /// At AX2 and larger the title drops the face (spec 06 §10).
    private var showsAccessory: Bool {
        guard accessory != nil else { return false }
        // The app's text size, not this view's: the bar caps its items' size category.
        let category = window?.windowScene?.traitCollection.preferredContentSizeCategory ?? UIApplication.shared.preferredContentSizeCategory
        return !category.isAccessibilityCategory || category == .accessibilityMedium
    }
    var title: String = "" {
        didSet {
            nameLabel.text = title
            applyLook()
            setName()
            updateLabel()
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }
    /// [tasks-first] A menu the title opens on a tap, in place of `onTap` (a task's page: the list the task is in,
    /// to move it). A small up-and-down chevron follows the name while it has one.
    var menu: UIMenu? {
        didSet {
            menuButton.menu = menu
            menuButton.isHidden = menu == nil
            guard (menu == nil) != (oldValue == nil) else { return }
            accessibilityHint = menu == nil ? nil : "Shows a menu"
            setName()
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }
    private let menuButton: UIButton = {
        let button = UIButton(type: .custom)
        button.showsMenuAsPrimaryAction = true
        button.isHidden = true
        button.isAccessibilityElement = false
        return button
    }()

    /// UX study #248: the chat's bot is muted; a bell.slash follows the name and VoiceOver says "Muted".
    var muted = false {
        didSet {
            guard muted != oldValue else { return }
            setName()
            updateLabel()
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    private func updateLabel() {
        accessibilityLabel = [title, muted ? "Muted" : nil, subtitle].compactMap { $0 }.joined(separator: ", ")
    }

    /// The name with the muted bell after it (Desktop Look draws its capitals in `applyLook`, on every layout).
    private func setName() {
        if Theme.isDesktop { setNeedsLayout(); return }
        if muted || menu != nil, let font = nameLabel.font {
            nameLabel.attributedText = nameText(title, attributes: [.font: font, .foregroundColor: ChatPalette.label])
        } else if nameLabel.attributedText?.containsAttachments(in: NSRange(location: 0, length: nameLabel.attributedText?.length ?? 0)) == true
                    || nameLabel.text != title {
            nameLabel.text = title
        }
    }

    private func nameText(_ text: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let name = NSMutableAttributedString(string: text, attributes: attributes)
        guard let font = attributes[.font] as? UIFont else { return name }
        // The muted bell, then the menu's chevron, each a hair after the name.
        for symbol in [muted ? "bell.slash" : nil, menu != nil ? "chevron.up.chevron.down" : nil].compactMap({ $0 }) {
            guard let mark = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small)) else { continue }
            name.append(NSAttributedString(string: "\u{2009}", attributes: attributes))
            name.append(NSAttributedString(attachment: NSTextAttachment(image: mark.withTintColor(ChatPalette.label2, renderingMode: .alwaysOriginal))))
        }
        return name
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(glass)
        nameLabel.textColor = ChatPalette.label
        nameLabel.lineBreakMode = .byTruncatingTail
        glass.contentView.addSubview(nameLabel)
        subtitleLabel.textColor = ChatPalette.label2
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.isHidden = true
        glass.contentView.addSubview(subtitleLabel)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        glass.addGestureRecognizer(tap)
        addSubview(menuButton)   // over the glass: with a menu, the tap is the menu's
        isAccessibilityElement = true
        accessibilityTraits = .header
        accessibilityIdentifier = "chat.title"
        DesktopLayout.keepOwnLook(glass)          // [desktoplook2] the look draws this as the desktop's open tab
        layer.addSublayer(rule)
        updateFont()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: ChatTitleView, _) in
            view.updateFont()
            view.setNeedsLayout()
            view.onSizeChange?()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The title's size changed (Dynamic Type): the bar re-reads it.
    var onSizeChange: (() -> Void)?

    private func updateFont() {
        var size = min(HQFont.preferred(.headline, compatibleWith: traitCollection).pointSize, 22)
        // [ui-sizing 2026-11-09] The footnote as UIKit sizes it (Dynamic Type and UI Scale once, capped at 18). It was
        // scaled for UI Scale a second time, and with the name over it the pair outgrew the 44 pt glass from about
        // 125 %: the bot's line hung under the pill. With a subtitle both shrink together until they fit; 17 + 13 at
        // 100 % already does.
        var sub = min(HQFont.preferred(.footnote, compatibleWith: traitCollection).pointSize, 18)
        if subtitle != nil {
            let room: CGFloat = 44 - 4, lines = (size + sub) * 1.2
            if lines > room { size *= room / lines; sub *= room / lines }
        }
        nameLabel.font = HQFont.face(ofSize: size, weight: .semibold)
        subtitleLabel.font = HQFont.face(ofSize: sub)
        if muted { setName() }
        invalidateIntrinsicContentSize()
    }

    /// The look or UI Scale changed: this look's fonts, before the bar measures the title again. Mac polish #80: the
    /// Desktop Look never refreshed them, so after a live switch the bot's line kept the iOS look's size (smaller on
    /// the Mac, whose looks start at different scales) and the accent rule under it came out short.
    func themeChanged() {
        updateFont()
        applyLook()
        setNeedsLayout()
    }

    private var maxWidth: CGFloat {
        let screen = window?.bounds.width ?? 402   // [m9/ipad] the window's width, not the screen's
        return min(screen * 0.66, 300)
    }

    override var intrinsicContentSize: CGSize {
        if Theme.isDesktop {   // [desktoplook2] 10 pt each side, a 22 pt face 7 pt before the name
            let accessoryW: CGFloat = showsAccessory ? 22 + 7 : 0
            var nameW = ceil(nameLabel.intrinsicContentSize.width)
            if subtitle != nil { nameW = max(nameW, ceil(subtitleLabel.intrinsicContentSize.width)) }
            return CGSize(width: min(maxWidth, 10 + accessoryW + nameW + 10), height: 44)
        }
        let accessoryW: CGFloat = showsAccessory ? 34 + 10 : 0
        let pad: CGFloat = showsAccessory ? 5 : 14
        var nameW = ceil(nameLabel.intrinsicContentSize.width)
        if subtitle != nil { nameW = max(nameW, ceil(subtitleLabel.intrinsicContentSize.width)) }
        return CGSize(width: min(maxWidth, pad + accessoryW + nameW + 14), height: 44)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize { intrinsicContentSize }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        menuButton.frame = bounds
        applyLook()
        if Theme.isDesktop { layoutDesktop(); return }
        var x: CGFloat = showsAccessory ? 5 : 14
        accessory?.isHidden = !showsAccessory
        if let accessory, showsAccessory {
            accessory.frame = CGRect(x: x, y: (bounds.height - 34) / 2, width: 34, height: 34)
            x += 34 + 10
        }
        let width = max(0, bounds.width - x - 14)
        if subtitle != nil, let nameFont = nameLabel.font, let subFont = subtitleLabel.font {
            // Name over the bot's name, centred as a pair in the 44 pt glass.
            let nameH = ceil(nameFont.lineHeight), subH = ceil(subFont.lineHeight)
            let top = max(0, (bounds.height - nameH - subH) / 2)
            nameLabel.frame = CGRect(x: x, y: top, width: width, height: nameH)
            subtitleLabel.frame = CGRect(x: x, y: top + nameH, width: width, height: subH)
        } else {
            nameLabel.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
        }
    }

    // MARK: [desktoplook2] The desktop's open tab (phone-ui-desktop.css:230-236): no box, the name in tracked
    // capitals over a 2 pt accent rule, a small face before it.

    private let rule = CALayer()
    private var desktopDrawn = false

    private func applyLook() {
        let desktop = Theme.isDesktop
        rule.isHidden = !desktop
        if desktop {
            if glass.effect != nil { glass.effect = nil }
            glass.backgroundColor = .clear
            glass.layer.borderWidth = 0
            rule.backgroundColor = HQPalette.tintText.resolvedColor(with: traitCollection).cgColor
            let size = 13 * HQFont.dynamicRatio(traitCollection) * HQFont.scale
            let font = HQFont.system(ofSize: 13 * HQFont.dynamicRatio(traitCollection), weight: .semibold)
            nameLabel.attributedText = nameText(title.uppercased(),
                                                attributes: [.font: font, .foregroundColor: ChatPalette.label, .kern: size * 0.06])
            desktopDrawn = true
        } else if desktopDrawn {
            desktopDrawn = false
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = true
            glass.effect = effect
            glass.backgroundColor = nil
            nameLabel.attributedText = nil
            nameLabel.text = title
            nameLabel.textColor = ChatPalette.label
            updateFont()
        }
        #if targetEnvironment(macCatalyst)
        // [mac] Stress test 2026-10-28 #50: a Mac toolbar's title is plain words, not a glass pill (Kanban's and
        // Settings' have none): the face and name stay, the glass goes.
        if !desktop, glass.effect != nil { glass.effect = nil }
        #endif
    }

    private func layoutDesktop() {
        var x: CGFloat = 10
        accessory?.isHidden = !showsAccessory
        if let accessory, showsAccessory {
            accessory.frame = CGRect(x: x, y: (bounds.height - 22) / 2, width: 22, height: 22)
            x += 22 + 7
        }
        let width = max(0, bounds.width - x - 10)
        if subtitle != nil, let nameFont = nameLabel.font, let subFont = subtitleLabel.font {
            let nameH = ceil(nameFont.lineHeight), subH = ceil(subFont.lineHeight)
            let top = max(0, (bounds.height - nameH - subH) / 2)
            nameLabel.frame = CGRect(x: x, y: top, width: width, height: nameH)
            subtitleLabel.frame = CGRect(x: x, y: top + nameH, width: width, height: subH)
        } else {
            nameLabel.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rule.frame = CGRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2)
        CATransaction.commit()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if Theme.isDesktop { applyLook() }
    }

    @objc private func tapped() {
        UIView.animate(withDuration: 0.1, animations: { self.alpha = 0.6 }) { _ in   // motion-ok: opacity only
            UIView.animate(withDuration: 0.15) { self.alpha = 1 }
        }
        onTap?()
    }
}

/// The status line under the title (spec 06 §4.1): a small glass capsule with three working dots and the words.
/// The transcript reserves its height whether or not it shows, so it never moves anything.
final class ChatStatusPill: UIView {
    private let glass: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        view.cornerConfiguration = .capsule()
        return view
    }()
    private let label = UILabel()
    private var dots: [UIView] = []
    private(set) var text: String?
    /// UX study #121: while signed out the pill is a button that signs in again (nil: never tappable).
    var onSignIn: (() -> Void)? { didSet { updateTappable() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(glass)
        label.lineBreakMode = .byTruncatingTail
        glass.contentView.addSubview(label)
        for _ in 0..<3 {
            let d = UIView()
            d.layer.cornerRadius = 1.5
            glass.contentView.addSubview(d)
            dots.append(d)
        }
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
        alpha = 0
        updateFont()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: ChatStatusPill, _) in view.updateFont() }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The pill reads "Signed Out" (HeaderLink) and a sign-in is wired.
    var offersSignIn: Bool { onSignIn != nil && text == "Signed Out" }

    private func updateTappable() {
        let on = offersSignIn
        isUserInteractionEnabled = on
        accessibilityTraits = on ? [.button, .updatesFrequently] : .updatesFrequently
        accessibilityHint = on ? "Signs in again." : nil
    }

    @objc private func tapped() {
        guard offersSignIn else { return }
        onSignIn?()
    }

    /// The pill is 22 pt tall: a tap a little above or below it still lands (44 pt in all).
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -4, dy: -11).contains(point)
    }

    private func updateFont() {
        let size = min(HQFont.preferred(.footnote, compatibleWith: traitCollection).pointSize, 18)
        label.font = HQFont.face(ofSize: size)
        invalidateIntrinsicContentSize()
    }

    /// [ui-sizing] The look or UI Scale changed.
    func themeChanged() { updateFont(); setNeedsLayout() }

    /// Words that read as trouble take the orange tone; working words take the working tone.
    func set(_ text: String?) {
        guard text != self.text else { return }
        self.text = text
        accessibilityLabel = text
        let attention = text.map { $0.hasPrefix("Waiting for your") } ?? false
        let quiet = text.map { ["Offline", "Reconnecting…", "Can’t reach this bot", "Waking up…", "Still waking up…", "Connecting…"].contains($0)   /* [transcript] */ } ?? false
        let color = attention ? ChatPalette.orange : quiet ? ChatPalette.label2 : ChatPalette.statusWorking
        label.text = text
        updateTappable()
        // Verify round 2: the untinted glass takes on what is under it, and over one of your own blue bubbles blue words
        // fell under 4.5:1 (4.0). Working words are in the label colour; the dots keep the working tone.
        label.textColor = attention || quiet ? color : ChatPalette.label
        dots.forEach { $0.backgroundColor = color; $0.isHidden = quiet || attention }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        // [perf] The dots' repeating animations stop once the pill has faded out (or while the dots are hidden), so an
        // idle chat runs none; `animateDots` restarts them when the working words come back.
        UIView.animate(withDuration: 0.2, animations: { self.alpha = text == nil ? 0 : 1 }, completion: { _ in   // motion-ok: opacity only
            if self.text == nil { self.stopDots() }
        })
        if text != nil && !(quiet || attention) { animateDots() } else if text != nil { stopDots() }
    }

    /// The dots are animating (tests).
    var dotsAnimating: Bool { dots.contains { $0.layer.animation(forKey: "dot") != nil } }

    private func stopDots() { dots.forEach { $0.layer.removeAnimation(forKey: "dot") } }

    override var intrinsicContentSize: CGSize {
        let dotsW: CGFloat = dots.first?.isHidden == false ? 13 + 6 : 0
        // [ui-sizing 2026-11-09] 22 pt, or taller when its words are (up to 18 pt): at the cap they touched the capsule's
        // edges. The width limit follows UI Scale and the window, so long words aren't cut sooner at a larger scale.
        let most = min(HQFont.scaled(240), max(240, (window?.bounds.width ?? 375) - 32))
        let w = min(most, 10 + dotsW + ceil(label.intrinsicContentSize.width) + 10)
        return CGSize(width: w, height: max(22, ceil(label.font.lineHeight) + 4))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        var x: CGFloat = 10
        if dots.first?.isHidden == false {
            for (i, d) in dots.enumerated() { d.frame = CGRect(x: x + CGFloat(i) * 5, y: (bounds.height - 3) / 2, width: 3, height: 3) }
            x += 13 + 6
        }
        label.frame = CGRect(x: x, y: 0, width: max(0, bounds.width - x - 10), height: bounds.height)
    }

    private func animateDots() {
        guard !HQMotion.reduced else { return }
        let now = CACurrentMediaTime()
        for (i, d) in dots.enumerated() where d.layer.animation(forKey: "dot") == nil {
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = [0.4, 1, 0.4, 0.4]
            a.keyTimes = [0, 0.3, 0.6, 1]
            a.duration = 1.2
            a.repeatCount = .infinity
            a.beginTime = now + Double(i) * 0.2
            a.fillMode = .backwards
            d.layer.add(a, forKey: "dot")
        }
    }
}

/// A one-line notice under the title ("Couldn't stop — Hermes finished the reply.", a refused send's reason): a small
/// glass capsule that fades in, stays 3 s and fades out. VoiceOver reads it as an announcement. [questions] It can carry
/// one action ("Reconnect" on the offline answers, spec 1x §4.7): it then takes touches and stays 5 s on the Undo
/// pill's clock — at least 8 s at accessibility text sizes, held while a finger rests on it or VoiceOver focus is inside.
final class ChatNoticeToast: UIView {
    private let glass: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        view.cornerConfiguration = .capsule()
        return view
    }()
    private let label = UILabel()
    private let actionButton = NoticeActionButton(type: .system)
    private var action: (() -> Void)?
    private var hideWork: DispatchWorkItem?
    /// [a11y] An actionable notice's clock (the Undo pill's rules); nil for a plain notice's fixed time.
    private var clock: UndoPillClock?
    private var focusObserver: NSObjectProtocol?

    isolated deinit {
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
    }
    /// MENUS (spec 1x §5.3): leads a notice that stays while something runs ("Switching to …").
    private let spinner = UIActivityIndicatorView(style: .medium)
    /// [mac] Shown, until `hide()`: the chat draws a page-coloured backing behind it meanwhile.
    private(set) var isShowing = false
    var onShowingChange: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        alpha = 0
        addSubview(glass)
        glass.translatesAutoresizingMaskIntoConstraints = false
        label.font = HQFont.preferred(.footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = ChatPalette.label
        label.numberOfLines = 2
        label.textAlignment = .center
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 0)
        config.baseForegroundColor = ChatPalette.tintText
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a; a.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: HQFont.system(ofSize: 13, weight: .semibold)); return a
        }
        actionButton.configuration = config
        actionButton.isHidden = true
        actionButton.accessibilityIdentifier = "chat.notice.action"
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.addAction(UIAction { [weak self] _ in self?.actionTapped() }, for: .primaryActionTriggered)
        spinner.hidesWhenStopped = true
        spinner.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        let row = UIStackView(arrangedSubviews: [spinner, label, actionButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -14),
            actionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),   // touches 44 pt tall (NoticeActionButton)
        ])
        accessibilityIdentifier = "chat.notice"
        // [a11y] A resting finger holds an actionable notice; so does VoiceOver focus on it or its button.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(holding(_:)))
        hold.minimumPressDuration = 0
        hold.cancelsTouchesInView = false
        hold.delegate = self
        addGestureRecognizer(hold)
        focusObserver = NotificationCenter.default.addObserver(forName: UIAccessibility.elementFocusedNotification, object: nil,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setHold(.voiceOver, self.holdsFocus(UIAccessibility.focusedElement(using: .notificationVoiceOver) as AnyObject?))
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// [questions] With an action ("Reconnect"): 5 s and tappable (8 s at accessibility sizes, held while touched or
    /// VoiceOver-focused); otherwise 3 s (8 s at accessibility sizes).
    func show(_ text: String, action: (title: String, handler: () -> Void)? = nil) {
        show(text, duration: action == nil ? 3 : 5, spinner: false, action: action)
    }

    /// Settings stream: `seconds: nil` keeps the notice until it is tapped (New Bot without a model provider: the user
    /// may look away while the chat opens and must still learn why the bot didn't introduce itself); `lines` 0 wraps.
    func show(_ text: String, lines: Int, seconds: TimeInterval?) {
        show(text, duration: seconds, spinner: false, lines: lines, dismissOnTap: seconds == nil)
    }

    /// MENUS: `duration` nil keeps the notice until it is replaced or hidden (or, with `dismissOnTap`, tapped); a
    /// replacement keeps the capsule in place and swaps its words.
    func show(_ text: String, duration: TimeInterval?, spinner showsSpinner: Bool,
              action: (title: String, handler: () -> Void)? = nil, lines: Int = 2, dismissOnTap: Bool = false) {
        guard !text.isEmpty else { return }
        label.numberOfLines = lines
        label.text = text
        accessibilityLabel = text
        if showsSpinner { spinner.startAnimating() } else { spinner.stopAnimating() }
        self.action = action?.handler
        actionButton.configuration?.title = action?.title
        actionButton.isHidden = action == nil
        // A wrapping label beside an action has no width of its own: it wraps at the widest the capsule may be (the
        // screen less 48 pt, its 28 pt of padding and the action), never squeezed to a word ("Using the i…").
        let room = (superview?.bounds.width ?? window?.bounds.width ?? bounds.width) - 48 - 28   // the view's own room (an iPad pane)
        label.preferredMaxLayoutWidth = max(80, room - (action == nil ? 0 : 6 + max(64, actionButton.intrinsicContentSize.width)))
        label.invalidateIntrinsicContentSize()
        let sticky = dismissOnTap && action == nil
        isUserInteractionEnabled = action != nil || sticky
        isAccessibilityElement = sticky
        accessibilityHint = sticky ? "Double-tap to dismiss." : nil
        if sticky, tapToDismiss == nil {
            let tap = UITapGestureRecognizer(target: self, action: #selector(dismissTapped))
            addGestureRecognizer(tap)
            tapToDismiss = tap
        }
        tapToDismiss?.isEnabled = sticky
        hideWork?.cancel()
        hideWork = nil
        layer.removeAllAnimations()
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState]) { self.alpha = 1 }   // motion-ok: opacity only
        if !isShowing { isShowing = true; onShowingChange?() }
        HQAnnounce.say(text)
        clock = nil
        guard let duration else { return }
        let category = traitCollection.preferredContentSizeCategory
        let large = category.isAccessibilityCategory || UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory
        // A plain notice at accessibility sizes stays as long as an actionable one (8 s): larger words take longer to
        // read (3 s left them half read).
        guard action != nil else { arm(UndoPillClock(duration: duration, accessibilitySize: large).remaining); return }
        var next = UndoPillClock(duration: duration, accessibilitySize: large)
        if holdsFocus(UIAccessibility.focusedElement(using: .notificationVoiceOver) as AnyObject?) { next.hold(.voiceOver, now: Date()) }
        clock = next
        if let left = clock?.resume(now: Date()) { arm(left) }
    }

    private func arm(_ seconds: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// [a11y] A hold stops an actionable notice's clock and keeps what is left; letting go runs the rest.
    private func setHold(_ hold: UndoPillClock.Hold, _ on: Bool) {
        guard var running = clock else { return }
        if on {
            guard !running.holds.contains(hold) else { return }
            running.hold(hold, now: Date())
            hideWork?.cancel(); hideWork = nil
            clock = running
        } else {
            guard running.holds.contains(hold) else { return }
            let left = running.release(hold, now: Date())
            clock = running
            if let left { arm(left) }
        }
    }

    @objc private func holding(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began: setHold(.finger, true)
        case .ended, .cancelled, .failed: setHold(.finger, false)
        default: break
        }
    }

    private func holdsFocus(_ focused: AnyObject?) -> Bool {
        (focused as? UIView).map { $0.isDescendant(of: self) } ?? false
    }

    /// [a11y] The action's 44 pt touch area reaches past the row it sits in, so the capsule routes those touches to it.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if isUserInteractionEnabled, action != nil, !actionButton.isHidden,
           actionButton.point(inside: actionButton.convert(point, from: self), with: event) {
            return actionButton
        }
        return super.hitTest(point, with: event)
    }

    private var tapToDismiss: UITapGestureRecognizer?

    @objc private func dismissTapped() { hide() }

    override func accessibilityActivate() -> Bool {
        guard isAccessibilityElement, isUserInteractionEnabled else { return false }
        hide()
        return true
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        clock = nil
        isUserInteractionEnabled = false
        accessibilityHint = nil
        action = nil
        UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState]) { self.alpha = 0 } completion: { [weak self] done in   // motion-ok: opacity only
            if done, self?.alpha == 0 { self?.spinner.stopAnimating() }
        }
        if isShowing { isShowing = false; onShowingChange?() }
    }

    private func actionTapped() {
        let handler = action
        hide()
        handler?()
    }
}

extension ChatNoticeToast: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// [a11y] The notice's action keeps its 32 pt look but takes touches 44 pt tall (and a little either side).
private final class NoticeActionButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dy = max(0, (44 - bounds.height) / 2)
        return bounds.insetBy(dx: -6, dy: -dy).contains(point)
    }
}

/// UIKit draws a scroll view's edge effect only once a push has finished: the chat's soft top edge (the bar and the
/// status line, spec 06 §4.1) popped in at the end of every open, after the text had slid in sharp under the clock and
/// the title. This stands in for it during the push — the same region, blurred and fading into the page colour the
/// way the system's soft edge does — and fades out as the system's own edge takes over.
final class ChatEdgeStandIn: UIView {
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let blurMask = CAGradientLayer()
    private let wash = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        addSubview(blur)
        blurMask.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        blurMask.locations = [0, 0.55, 1]
        blur.layer.mask = blurMask
        layer.addSublayer(wash)
        wash.locations = [0, 0.45, 1]
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self, UITraitAccessibilityContrast.self]) { (view: ChatEdgeStandIn, _) in view.updateColors() }
        a11yToken = NotificationCenter.default.addObserver(forName: HQAccessibility.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateColors() }
        }
    }

    private var a11yToken: NSObjectProtocol?   // [a11y] Reduce Transparency flips while the chat is open
    isolated deinit { if let a11yToken { NotificationCenter.default.removeObserver(a11yToken) } }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func updateColors() {
        let page = ChatPalette.page.resolvedColor(with: traitCollection)
        // [a11y] Reduce Transparency: a solid band of the page colour, nothing showing through (the web's chat bar takes
        // the page colour, phone-ui-chat.css:286-288). The band still ends in a short fade so no hard line is drawn.
        let solid = HQAccessibility.reduceTransparency
        blur.isHidden = solid
        wash.colors = solid
            ? [page.cgColor, page.cgColor, page.withAlphaComponent(0).cgColor]
            : [page.withAlphaComponent(0.92).cgColor, page.withAlphaComponent(0.6).cgColor, page.withAlphaComponent(0).cgColor]
        wash.locations = solid ? [0, 0.8, 1] : [0, 0.45, 1]
        #if DEBUG
        accessibilityValue = solid ? "opaque=1" : "opaque=0"
        #endif
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        blur.frame = bounds
        blurMask.frame = bounds
        wash.frame = bounds
        CATransaction.commit()
    }

    /// The system's edge is up: fade out and go.
    func handOver() {
        guard superview != nil else { return }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {   // motion-ok: opacity only
            self.alpha = 0
        } completion: { _ in self.removeFromSuperview() }
    }
}
