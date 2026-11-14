import UIKit

/// The composer's ☰ commands button (spec 1x §7.1, spec 06 §4.3): SF `line.3.horizontal` in label-2 —
/// the same glyph size and weight as the + beside it (verify round 1: the 14-unit path drew ~12 pt lines next to a
/// ~19 pt +) — and a 48 pt touch target. Telegram's menu button; no haptic on tap (owner). [composer-bar] The composer
/// takes its glass away: it is a plain glyph on the bar, and a press shows the mic's soft 36 pt circle behind it.
final class ComposerGlassButton: UIVisualEffectView {
    var onTap: (() -> Void)?
    var isEnabled = true {
        didSet {
            alpha = isEnabled ? 1 : 0.4
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        }
    }

    private let glyph = UIImageView()
    private let symbol: String
    /// [composer-expand] On a 36 pt glass disc like the +'s (the two-row bar's buttons), the glyph in label.
    var showsDisc = false { didSet { if showsDisc != oldValue { disc.isHidden = !showsDisc; recolor() } } }
    private let disc: ComposerGlassDisc = {
        let view = ComposerGlassDisc()
        view.isHidden = true
        return view
    }()
    /// [composer-bar] The press, as the mic draws it (`MemoMicControl`): a Fill 3 circle 4 pt in from the slot.
    private let pressedCircle = ComposerGlassButton.makePressedCircle()

    static func makePressedCircle() -> UIView {
        let circle = UIView()
        circle.backgroundColor = ChatPalette.fill3
        circle.isUserInteractionEnabled = false
        circle.alpha = 0
        return circle
    }

    /// Shows or hides `circle` for a press. Only in the iOS look: the Desktop Look's box keeps its quiet icons.
    static func showPress(_ circle: UIView, _ down: Bool) {
        let show = down && !ComposerView.oneBox
        guard (circle.alpha > 0.5) != show else { return }
        UIView.animate(withDuration: show ? 0.08 : 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {   // motion-ok: opacity only
            circle.alpha = show ? 1 : 0
        }
    }

    /// [composer-bar] 20 pt regular, the mic's own glyph, so the three glyphs on the bar draw one weight (18 pt medium
    /// read heavier than the mic beside them); the Desktop Look's lighter 16 pt regular (the desktop's thin-line composer
    /// icons, owner 2026-10-15: the bold ☰ and + read cheap). Shared with the + button.
    static var glyphConfiguration: UIImage.SymbolConfiguration {
        // [mac] Stress test 2026-10-28 #69: the Mac's Desktop Look box is 51 pt tall (Grok Bot's), not the iPhone's 40,
        // and its 16 pt ☰ and + read as specks beside the 20 pt mic; they grow with the box (16 × 51 / 40 ≈ 20).
        ComposerView.oneBox ? UIImage.SymbolConfiguration(pointSize: DeviceWord.isMac ? 20 : 16, weight: .regular)
                        : UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
    }

    /// On a disc: the +'s own 17 pt semibold.
    static var discConfiguration: UIImage.SymbolConfiguration { UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold) }

    /// `symbol`: an SF Symbol drawn like the + button's (label-2, `glyphConfiguration`).
    init(symbol: String, label: String, identifier: String) {
        let glass = UIGlassEffect(style: .regular)
        glass.isInteractive = true
        self.symbol = symbol
        super.init(effect: glass)
        cornerConfiguration = .capsule()
        glyph.contentMode = .center
        glyph.isUserInteractionEnabled = false
        contentView.addSubview(disc)
        contentView.addSubview(pressedCircle)
        contentView.addSubview(glyph)
        #if targetEnvironment(macCatalyst)
        // [mac] Feel list B (2026-11-13): ☰ answers the pointer as the + beside it does (it is not a control, so the
        // app's hover never found it): the same disc, deeper while it is down.
        MacHover.surface(self, shape: .button, above: disc, host: contentView)
        #endif
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = label
        accessibilityIdentifier = identifier
        // [a11y] The glyph keeps its size at the accessibility text sizes; a hold shows it large, named.
        showsLargeContentViewer = true
        largeContentTitle = label
        largeContentImage = UIImage(systemName: symbol)
        scalesLargeContentImage = true
        addInteraction(UILargeContentViewerInteraction())
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: ComposerGlassButton, _) in view.recolor() }
        recolor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A 48 pt hit box around the 44 pt slot.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -2, dy: -2).contains(point)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glyph.frame = contentView.bounds
        pressedCircle.frame = contentView.bounds.insetBy(dx: 4, dy: 4)
        pressedCircle.layer.cornerRadius = pressedCircle.bounds.width / 2
        disc.bounds = CGRect(origin: .zero, size: pressedCircle.frame.size)   // (the press scales it: no frame)
        disc.center = CGPoint(x: pressedCircle.frame.midX, y: pressedCircle.frame.midY)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        if isEnabled { press(true) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        press(false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        press(false)
    }

    /// On its disc the glass sinks; a bare glyph shows the soft circle.
    private func press(_ down: Bool) {
        if showsDisc { disc.press(down) } else { Self.showPress(pressedCircle, down) }
        // [mac] The Desktop Look's box shows no circle (`showPress`): there the press is the hover's disc, deeper.
        if ComposerView.oneBox { PointerEffects.press(self, down) }
    }

    private func recolor() {
        pressedCircle.backgroundColor = ChatPalette.fill3
        glyph.tintColor = showsDisc ? ChatPalette.label : ChatPalette.composerGlyph
        glyph.image = UIImage(systemName: symbol, withConfiguration: showsDisc ? Self.discConfiguration : Self.glyphConfiguration)
    }

    @objc private func tapped() {
        guard isEnabled else { return }
        onTap?()
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        onTap?()
        return true
    }
}

/// [composer-glass] The two-row bar's discs (+, ☰, the mic, Dictate) and its model bubble each stand on Liquid Glass of
/// their own (owner 2026-10-31: "all of the bubbles in the chat thing to be liquid glass"): a lens on the bar's glass,
/// whose edge catches the light. A press sinks it a little (it dims instead under Reduce Motion). `tint` colours the
/// glass: the bubble, while its panel is open. The Desktop Look never shows these.
final class ComposerGlassDisc: UIVisualEffectView {
    var tint: UIColor? { didSet { if tint != oldValue { glaze() } } }

    init() {
        super.init(effect: nil)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        cornerConfiguration = .capsule()
        glaze()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func glaze() {
        let glass = UIGlassEffect(style: .regular)
        glass.tintColor = tint
        effect = glass
    }

    func press(_ down: Bool) {
        HQMotion.spring(duration: 0.32, damping: 0.8, changes: {
            self.transform = down ? CGAffineTransform(scaleX: 0.9, y: 0.9) : .identity
        }, reduced: { self.alpha = down ? 0.6 : 1 })
    }
}
