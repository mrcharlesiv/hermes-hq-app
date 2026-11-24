// [Mac model selector] Owner 2026-11-17, design B ("One panel: the Models list grows a settings strip"). On the Mac the
// app had two model selectors: the iPhone's model card, centred over the chat (owner 2026-11-08), and the list-style
// Models pop-over (☰ Commands › Models, /model). He found the card "is not a good UX for Mac at all" and chose B: the
// Models pop-over is the one selector, hung off the model's name in the message box, and at its foot a slim card with
// what the model card set (Thinking, Fast, YOLO, Approval Mode) and one quiet line of its facts, each opening its page.
//
// The pieces here are drawn for that foot and read and act exactly as the card does: the same `ModelPanelState`
// (`ChatMenus.modelPanelState`), the same `ModelPanelActions` (built once by `ChatMenus.modelPanelActions`), the same
// words (`ModelPanelModel.effortLine`, `approvalModes`, `approvalsReach`), the same alerts (the switcher's and
// `ChatMenus.failure`). The owner's answers on the open points: calm (the bar stays lit, no light show and no acting
// face), and the panel stays open after a pick. The iPhone and iPad keep the card (ModelPanel.swift), untouched.

#if targetEnvironment(macCatalyst)
import UIKit

// MARK: - The line under the search field

/// "For this chat only" and, at its end, "[face] Otto’s default ›", which opens the bot's Bot Info (its default,
/// fallback and auxiliary models): the card's scope note and its corner face, in one line.
@MainActor final class MacModelScopeLine: UIView, MacPickPanelPiece {
    private let scope = UILabel()
    private let link = UIButton(type: .system)
    private let face: HeadView?
    private static let faceSide: CGFloat = 20

    init(bot: (name: String, open: () -> Void)?, head: (raw: JSONValue?, profile: String)) {
        let words = ModelPanelModel.macScope(bot: bot?.name)
        face = bot == nil ? nil : HeadView(side: Self.faceSide)
        super.init(frame: .zero)
        scope.text = words.scope
        scope.font = MacType.row
        scope.accessibilityLabel = ModelPanelModel.switchScope(bot: bot?.name)
        addSubview(scope)
        if let bot, let face, let title = words.link {
            face.configure(raw: head.raw, profile: head.profile)
            face.isUserInteractionEnabled = false
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 6 + Self.faceSide + 6, bottom: 2, trailing: 6)
            config.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: MacType.row]))
            config.image = UIImage(systemName: "chevron.forward", withConfiguration: UIImage.SymbolConfiguration(font: HQFont.preferred(.footnote).pagesWeight(.semibold)))
            config.imagePlacement = .trailing
            config.imagePadding = 5
            config.titleLineBreakMode = .byTruncatingTail
            link.configuration = config
            link.titleLabel?.numberOfLines = 1
            link.addSubview(face)
            link.addAction(UIAction { _ in bot.open() }, for: .primaryActionTriggered)
            link.accessibilityLabel = title
            link.accessibilityHint = "Opens Bot Info: its default model, fallback models and auxiliary models"
            link.accessibilityIdentifier = "model.panel.face"
            link.toolTip = "Bot Info: \(bot.name)’s default, fallback and auxiliary models"
            MacHover.button(link)
            addSubview(link)
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (line: MacModelScopeLine, _) in line.recolor() }
        recolor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func recolor() {
        scope.textColor = HQPalette.label2
        link.tintColor = ChatPalette.tintText
    }

    func pieceHeight(width: CGFloat) -> CGFloat { (MacType.row.lineHeight + 10).rounded() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = MacPickPanel.inset
        let h = bounds.height
        let lineH = ceil(scope.font.lineHeight)
        guard !link.isHidden, link.superview != nil else {
            scope.frame = CGRect(x: inset + MacPickRowCell.textInset, y: ((h - lineH) / 2).rounded(), width: bounds.width - 2 * inset, height: lineH)
            return
        }
        // [Mac AAA 2026-11-17] In a narrow chat (beside an open task) "For this chat only" was cut to "For this chat o…"
        // beside the face and the link. The scope stays whole: the face steps out first, then the link's name is cut.
        let x = inset + MacPickRowCell.textInset
        let room = bounds.width - inset + 6 - x - 8
        let need = ceil(scope.intrinsicContentSize.width)
        func linkWidth() -> CGFloat { ceil(link.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: h)).width) }
        setFace(shown: true)
        if need + linkWidth() > room { setFace(shown: false) }
        let linkW = min(linkWidth(), max(room - need, bounds.width * 0.3), bounds.width * 0.6)
        link.frame = CGRect(x: bounds.width - inset - linkW + 6, y: 0, width: linkW, height: h)
        face?.frame = CGRect(x: 6, y: ((h - Self.faceSide) / 2).rounded(), width: Self.faceSide, height: Self.faceSide)
        scope.frame = CGRect(x: x, y: ((h - lineH) / 2).rounded(), width: max(0, link.frame.minX - x - 8), height: lineH)
    }

    /// The face before the link's name, or not (its room in the button's leading inset goes with it).
    private func setFace(shown: Bool) {
        guard let face, face.isHidden == shown, var config = link.configuration else { return }
        face.isHidden = !shown
        config.contentInsets.leading = shown ? 6 + Self.faceSide + 6 : 6
        link.configuration = config
    }
}

// MARK: - Thinking: a lit step bar

/// The model card's lit thinking bar at the Mac's size (a 16 pt track, a 24 pt knob, a dot at each level), calm: no
/// lights running and no drive behind it (owner 2026-11-17). A click on any step jumps there and a drag follows; with
/// the keyboard on it, ← and → step. `.valueChanged` fires on each level crossed, `.primaryActionTriggered` once it
/// settles (a let-go, or a pause after the last key).
final class MacThinkingSteps: UIControl {
    var stops: [String] = [] {
        didSet {
            guard stops != oldValue else { return }
            stop = min(stop, max(0, stops.count - 1))
            setNeedsLayout()
        }
    }
    private(set) var stop = 0
    var level: String? { stops.indices.contains(stop) ? stops[stop] : nil }
    var keyMarked = false { didSet { if keyMarked != oldValue { ring.isHidden = !keyMarked } } }

    private let track = CAShapeLayer()
    private let lit = CAShapeLayer()
    private let litDots = CAShapeLayer()
    private let darkDots = CAShapeLayer()
    private let knob = UIView()
    private let ring = UIView()
    private var hovering = false
    private var dragging = false
    private var settleTimer: Timer?

    static let trackHeight: CGFloat = 16
    static let knobSide: CGFloat = 24
    static let dotSide: CGFloat = 5
    /// The bar's own height: the knob, and room for its focus ring.
    static let height: CGFloat = knobSide + 8

    override init(frame: CGRect) {
        super.init(frame: frame)
        for shape in [track, lit] {
            shape.fillColor = nil
            shape.lineWidth = Self.trackHeight
            shape.lineCap = .round
            shape.actions = ["strokeEnd": NSNull(), "path": NSNull(), "strokeColor": NSNull()]
            layer.addSublayer(shape)
        }
        for dots in [darkDots, litDots] {
            dots.actions = ["path": NSNull()]
            layer.addSublayer(dots)
        }
        knob.isUserInteractionEnabled = false
        knob.layer.borderWidth = 3
        knob.layer.shadowOffset = CGSize(width: 0, height: 1)
        knob.layer.shadowRadius = 3
        knob.layer.shadowOpacity = 0.35
        addSubview(knob)
        ring.isUserInteractionEnabled = false
        ring.isHidden = true
        ring.layer.cornerCurve = .continuous
        addSubview(ring)
        isAccessibilityElement = true
        accessibilityLabel = "Thinking"
        accessibilityTraits = .adjustable
        accessibilityIdentifier = "model.panel.thinking"
        MacHover.drawsOwnHover(self)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        addGestureRecognizer(hover)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (bar: MacThinkingSteps, _) in bar.recolor() }
        recolor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isEnabled: Bool { didSet { alpha = isEnabled ? 1 : 0.45 } }
    override var accessibilityTraits: UIAccessibilityTraits {
        get { isEnabled ? super.accessibilityTraits : super.accessibilityTraits.union(.notEnabled) }
        set { super.accessibilityTraits = newValue }
    }

    private func recolor() {
        let t = traitCollection
        track.strokeColor = ChatPalette.label.resolvedColor(with: t).withAlphaComponent(0.13).cgColor
        lit.strokeColor = ChatPalette.tint.resolvedColor(with: t).cgColor
        litDots.fillColor = ChatPalette.onTint.resolvedColor(with: t).withAlphaComponent(0.9).cgColor
        darkDots.fillColor = ChatPalette.label.resolvedColor(with: t).withAlphaComponent(0.32).cgColor
        knob.backgroundColor = ChatPalette.tint
        knob.layer.borderColor = ChatPalette.onTint.resolvedColor(with: t).cgColor
        knob.layer.shadowColor = UIColor.black.cgColor
        ring.layer.borderColor = HQPalette.tint.resolvedColor(with: t).withAlphaComponent(Theme.isDesktop ? 1 : 0.6).cgColor
        ring.layer.borderWidth = HQShape.line(Theme.isDesktop ? 2 : 1.5)
    }

    private var from: CGFloat { Self.knobSide / 2 + 2 }
    private var to: CGFloat { bounds.width - Self.knobSide / 2 - 2 }

    private func position(_ index: Int) -> CGFloat { stops.count > 1 ? CGFloat(index) / CGFloat(stops.count - 1) : 0 }
    private func x(_ fraction: CGFloat) -> CGFloat { from + (to - from) * fraction }

    override func layoutSubviews() {
        super.layoutSubviews()
        let y = bounds.midY
        let line = UIBezierPath()
        line.move(to: CGPoint(x: from - Self.knobSide / 2 + Self.trackHeight / 2, y: y))
        line.addLine(to: CGPoint(x: to + Self.knobSide / 2 - Self.trackHeight / 2, y: y))
        for part in [track, lit, litDots, darkDots] { part.frame = bounds }
        track.path = line.cgPath
        knob.bounds = CGRect(x: 0, y: 0, width: Self.knobSide, height: Self.knobSide)
        knob.layer.cornerRadius = Self.knobSide / 2
        ring.frame = CGRect(x: 0, y: y - Self.height / 2, width: bounds.width, height: Self.height).insetBy(dx: -2, dy: 0)
        ring.layer.cornerRadius = Self.height / 2
        draw(fraction: position(stop))
    }

    private func draw(fraction: CGFloat) {
        guard stops.count > 1, to > from else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let y = bounds.midY
        let knobX = x(fraction)
        let litLine = UIBezierPath()
        litLine.move(to: CGPoint(x: from - Self.knobSide / 2 + Self.trackHeight / 2, y: y))
        litLine.addLine(to: CGPoint(x: max(from - Self.knobSide / 2 + Self.trackHeight / 2, knobX), y: y))
        lit.path = litLine.cgPath
        let on = UIBezierPath(), off = UIBezierPath()
        for i in stops.indices where i != stop || dragging {
            let p = position(i)
            let c = CGPoint(x: x(p), y: y)
            let dot = UIBezierPath(ovalIn: CGRect(x: c.x - Self.dotSide / 2, y: c.y - Self.dotSide / 2, width: Self.dotSide, height: Self.dotSide))
            if p <= fraction + 0.001 { on.append(dot) } else { off.append(dot) }
        }
        litDots.path = on.cgPath
        darkDots.path = off.cgPath
        knob.center = CGPoint(x: knobX, y: y)
        let grow: CGFloat = dragging ? 1.12 : hovering ? 1.06 : 1
        knob.transform = CGAffineTransform(scaleX: grow, y: grow)
        CATransaction.commit()
    }

    func setStop(_ index: Int) {
        stop = max(0, min(index, stops.count - 1))
        setNeedsLayout()
    }

    // MARK: Pointer

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        let on = isEnabled && (recognizer.state == .began || recognizer.state == .changed)
        guard on != hovering else { return }
        hovering = on
        HQMotion.animate(HQMotion.hover) { self.draw(fraction: self.position(self.stop)) }
    }

    private func nearest(_ px: CGFloat) -> Int {
        guard stops.count > 1 else { return 0 }
        let f = min(1, max(0, (px - from) / max(1, to - from)))
        return Int((f * CGFloat(stops.count - 1)).rounded())
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled, stops.count > 1 else { return false }
        dragging = true
        follow(touch.location(in: self).x)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        follow(touch.location(in: self).x)
        return true
    }

    private func follow(_ px: CGFloat) {
        let next = nearest(px)
        if next != stop {
            stop = next
            sendActions(for: .valueChanged)
        }
        draw(fraction: min(1, max(0, (px - from) / max(1, to - from))))
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        dragging = false
        HQMotion.animate(HQMotion.quick) { self.draw(fraction: self.position(self.stop)) }
        sendActions(for: .primaryActionTriggered)
    }

    override func cancelTracking(with event: UIEvent?) {
        dragging = false
        draw(fraction: position(stop))
    }

    // MARK: Keys and VoiceOver

    /// ← / → (and VoiceOver's swipes): one level, set once the keys pause, so a run of presses sends one change.
    func step(_ by: Int) {
        let next = max(0, min(stops.count - 1, stop + by))
        guard isEnabled, next != stop else { return }
        stop = next
        HQMotion.animate(HQMotion.quick) { self.draw(fraction: self.position(next)) }
        sendActions(for: .valueChanged)
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendActions(for: .primaryActionTriggered) }
        }
    }

    override func accessibilityIncrement() { step(1) }
    override func accessibilityDecrement() { step(-1) }
}

// MARK: - The settings card and the facts line

/// The selector's foot: Thinking (its name and line, the lit step bar), Fast and YOLO side by side, Approval Mode with
/// its pop-up, all on one soft card; under it the facts in one line. Tab stops: the bar, Fast, YOLO, Approval Mode.
@MainActor final class MacModelSettingsFoot: UIView, MacPickPanelFoot {
    private let actions: ModelPanelActions
    private(set) var state: ModelPanelState
    /// A model switch is on its way: the card waits for it (its settings are the old model's until it lands).
    var switching = false { didSet { if switching != oldValue { applyEnabled() } } }
    private var busy = false
    private(set) var closed = false

    private let card = UIView()
    private let lines = [UIView(), UIView(), UIView()]
    private let thinkingTitle = UILabel()
    private let thinkingValue = UILabel()
    private let valueTip = UIToolTipInteraction()
    private let bar = MacThinkingSteps()
    private let fast = MacSwitchHalf(symbol: "bolt.fill", name: "Fast", identifier: "model.panel.fast")
    private let yolo = MacSwitchHalf(symbol: "shield.slash.fill", name: "YOLO", identifier: "model.panel.skip")
    private let approvalIcon = UIImageView()
    private let approvalName = UILabel()
    private let approvalReach = UILabel()
    private let approvalButton = UIButton(type: .system)
    private let approvalRing = UIView()
    private let facts = MacFactsLine()
    private let offline = UILabel()

    init(state: ModelPanelState, actions: ModelPanelActions) {
        self.state = state
        self.actions = actions
        super.init(frame: .zero)
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        addSubview(card)
        lines.forEach { card.addSubview($0) }
        thinkingTitle.text = "Thinking"
        thinkingTitle.isAccessibilityElement = false
        thinkingValue.isAccessibilityElement = false
        thinkingValue.textAlignment = .right
        thinkingValue.lineBreakMode = .byTruncatingTail
        thinkingValue.isUserInteractionEnabled = true
        thinkingValue.addInteraction(valueTip)
        for view in [thinkingTitle, thinkingValue, bar, fast, yolo, approvalIcon, approvalName, approvalReach, approvalButton] as [UIView] {
            card.addSubview(view)
        }
        approvalRing.isUserInteractionEnabled = false
        approvalRing.isHidden = true
        approvalRing.layer.cornerCurve = .continuous
        card.addSubview(approvalRing)
        bar.addTarget(self, action: #selector(levelMoved), for: .valueChanged)
        bar.addTarget(self, action: #selector(effortChosen), for: .primaryActionTriggered)
        fast.onChange = { [weak self] on in self?.chooseFast(on) }
        yolo.onChange = { [weak self] on in self?.chooseYolo(on) }
        yolo.note = "No prompts in this chat"
        approvalName.text = "Approval Mode"
        approvalName.isAccessibilityElement = false
        approvalReach.isAccessibilityElement = false
        approvalReach.lineBreakMode = .byTruncatingTail
        approvalIcon.contentMode = .center
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 4)
        config.image = UIImage(systemName: "chevron.up.chevron.down", withConfiguration: UIImage.SymbolConfiguration(font: HQFont.preferred(.caption1).pagesWeight(.semibold)))
        config.imagePlacement = .trailing
        config.imagePadding = 3
        approvalButton.configuration = config
        approvalButton.showsMenuAsPrimaryAction = true
        approvalButton.preferredMenuElementOrder = .fixed
        approvalButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in completion(self?.approvalItems() ?? []) }])
        approvalButton.accessibilityIdentifier = "model.panel.approvals"
        approvalButton.toolTip = "Approval Mode: \(ModelPanelView.approvalsReach(bot: actions.bot?.name))"
        MacHover.button(approvalButton)
        // Under the card: the facts, each opening its page (the card's: Context Window, Model Prices, Usage & Limits).
        var opens: [String: (name: String, open: () -> Void)] = [
            "Price": ("Model Prices", actions.openPrices),
            "Plan": ("Usage & Limits", actions.openUsage)]
        if let open = actions.openContextWindow { opens[ModelPanelState.Fact.contextTitle] = ("Context Window", open) }
        facts.opens = opens
        addSubview(facts)
        offline.text = "Offline · changes wait for the gateway"
        offline.font = MacType.row
        offline.isHidden = true
        offline.accessibilityIdentifier = "model.panel.offline"
        addSubview(offline)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (foot: MacModelSettingsFoot, _) in foot.recolor() }
        recolor()
        apply(state)
        loadApprovalsIfUnknown()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The panel has gone: answers that land after it change nothing on screen.
    func panelClosed() { closed = true }

    private func recolor() {
        let desktop = Theme.isDesktop
        // The model card's own settings group (PanelGroup): frosted on the glass; on the Desktop Look's raised solid
        // surface, the look's editor fill with its line.
        card.backgroundColor = desktop ? ChatPalette.editor : HQPalette.glassPane
        card.layer.cornerRadius = HQShape.radius(12, .card)
        if desktop {
            card.layer.borderWidth = HQShape.hairline
            card.layer.borderColor = ChatPalette.strokeSecondary.resolvedColor(with: traitCollection).cgColor
        } else {
            card.hqGlassEdge(always: true)
        }
        lines.forEach { $0.backgroundColor = ChatPalette.label.withAlphaComponent(0.12) }
        thinkingTitle.font = MacType.row.pagesWeight(.semibold)
        thinkingTitle.textColor = ChatPalette.label
        approvalName.font = MacType.row
        approvalName.textColor = ChatPalette.label
        approvalReach.font = MacType.row
        approvalReach.textColor = ChatPalette.label2
        approvalButton.tintColor = ChatPalette.label
        approvalButton.configuration?.baseForegroundColor = ChatPalette.label
        approvalRing.layer.borderColor = HQPalette.tint.resolvedColor(with: traitCollection).withAlphaComponent(desktop ? 1 : 0.6).cgColor
        approvalRing.layer.borderWidth = HQShape.line(desktop ? 2 : 1.5)
        approvalRing.layer.cornerRadius = desktop ? DesktopRows.radius : 8
        offline.textColor = ChatPalette.orange
        relabel()
        showApprovals()
    }

    // MARK: State

    func apply(_ next: ModelPanelState) {
        let heightChanged = next.efforts.isEmpty != state.efforts.isEmpty || (next.efforts.count > 1) != (state.efforts.count > 1)
            || next.offline != state.offline || next.facts.isEmpty != state.facts.isEmpty
        state = next
        bar.stops = next.efforts
        bar.setStop(next.efforts.firstIndex(of: next.effort) ?? 0)
        relabel()
        fast.supported = next.fastSupported
        fast.on = next.fastSupported && next.fastOn
        fast.tipText = next.fastSupported ? "Fast: the model's quicker tier, in this chat" : "Not on this model"
        yolo.on = next.yolo
        showApprovals()
        facts.parts = ModelPanelModel.factParts(next.facts)
        offline.isHidden = !next.offline
        applyEnabled()
        if heightChanged { findPanel()?.footChanged() }
        setNeedsLayout()
    }

    private func findPanel() -> MacPickPanel? {
        var responder: UIResponder? = self
        while let next = responder?.next { if let panel = next as? MacPickPanel { return panel }; responder = next }
        return nil
    }

    private func applyEnabled() {
        let on = !state.offline && !switching
        bar.isEnabled = on
        fast.isEnabled = on && state.fastSupported
        yolo.isEnabled = on
        approvalButton.isEnabled = on
        approvalIcon.alpha = on ? 1 : 0.45
        approvalName.alpha = on ? 1 : 0.45
        // Usage & Limits and Model Prices read the gateway: offline their facts open nothing.
        facts.isEnabled = !state.offline
    }

    /// "High · Thinks hard": the level's name in semibold and what it means, as the card's bar says it.
    private func relabel() {
        let level = bar.level
        let name = level.map { ModelNames.effortLabel($0) }
        let line = level.map { state.efforts.count == 1 ? ModelPanelModel.effortLine($0) + " · its only level" : ModelPanelModel.effortLine($0) }
            ?? "This model answers without a thinking step"
        let text = NSMutableAttributedString()
        if let name {
            text.append(NSAttributedString(string: name, attributes: [.font: MacType.row.pagesWeight(.semibold), .foregroundColor: ChatPalette.label]))
            text.append(NSAttributedString(string: " · ", attributes: [.font: MacType.row, .foregroundColor: ChatPalette.label2]))
        }
        text.append(NSAttributedString(string: line, attributes: [.font: MacType.row, .foregroundColor: ChatPalette.label2]))
        thinkingValue.attributedText = text
        bar.accessibilityValue = [name, line].compactMap { $0 }.joined(separator: ", ")
        valueTip.defaultToolTip = nil
    }

    private func showApprovals() {
        let mode = state.approvalMode
        approvalIcon.image = UIImage(systemName: mode == "off" ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
        approvalIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: MacType.row.pagesWeight(.semibold))
        approvalIcon.tintColor = mode == "off" ? ChatPalette.orange : ChatPalette.tint
        let reach = ModelPanelView.approvalsReach(bot: actions.bot?.name)
        // "Every chat with Otto" reads "all Otto chats" beside the name (the pop-up's heading keeps the long form).
        approvalReach.text = actions.bot.map { "all \($0.name) chats" } ?? "all this bot’s chats"
        // Not known yet (an older Hermes, read once it opens): the card's row showed no word then, only its ⌃⌄.
        if let value = ModelPanelModel.approvalValue(mode: mode) {
            approvalButton.configuration?.attributedTitle = AttributedString(value, attributes: AttributeContainer([.font: MacType.row]))
        } else {
            approvalButton.configuration?.attributedTitle = nil
        }
        approvalButton.accessibilityLabel = "Approval Mode"
        approvalButton.accessibilityValue = [ModelPanelModel.approvalValue(mode: mode), reach].compactMap { $0 }.joined(separator: ", ")
        yolo.warning = state.yolo
        setNeedsLayout()
    }

    private func approvalItems() -> [UIMenuElement] {
        let now = actions.state() ?? state
        let modes = ModelPanelModel.approvalModes.map { entry in
            let action = UIAction(title: entry.name, subtitle: entry.line, state: now.approvalMode == entry.mode ? .on : .off) { [weak self] _ in
                self?.chooseApprovals(entry.mode)
            }
            action.accessibilityIdentifier = "model.panel.approvals.\(entry.mode)"
            return action
        }
        return [UIMenu(title: ModelPanelView.approvalsReach(bot: actions.bot?.name), options: .displayInline, children: modes)]
    }

    // MARK: Actions (as the card's)

    /// Reads the state again after a change landed (the card's `refresh`).
    func refresh() {
        guard !closed, let next = actions.state() else { return }
        apply(next)
    }

    @objc private func levelMoved() { relabel() }

    @objc private func effortChosen() {
        guard let level = bar.level, level != state.effort else { return }
        state.effort = level
        Task { @MainActor [weak self] in
            guard let self else { return }
            await actions.setEffort(level)
            refresh()
        }
    }

    private func chooseFast(_ on: Bool) {
        guard state.fastSupported, !busy else { fast.on = state.fastOn; return }
        state.fastOn = on
        busy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await actions.setFast(on)
            busy = false
            refresh()
        }
    }

    private func chooseYolo(_ on: Bool) {
        state.yolo = on
        showApprovals()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await actions.setYolo(on)
            refresh()
        }
    }

    private func chooseApprovals(_ mode: String) {
        guard mode != state.approvalMode else { return }
        state.approvalMode = mode
        showApprovals()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await actions.setApprovalMode(mode)
            refresh()
        }
    }

    /// An older Hermes leaves the approval mode out of the chat's info: read it, and the pop-up fills in.
    private func loadApprovalsIfUnknown() {
        guard state.approvalMode.isEmpty, !state.offline else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await actions.loadApprovals()
            if actions.state()?.approvalMode.isEmpty == false { refresh() }
        }
    }

    // MARK: Tab

    /// The bar (when the model has levels to step), Fast (when the model has it), YOLO, Approval Mode; offline or
    /// mid-switch, none (nothing there can be set).
    private var stopViews: [UIView] {
        guard !state.offline, !switching else { return [] }
        var out: [UIView] = []
        if state.efforts.count > 1 { out.append(bar) }
        if state.fastSupported { out.append(fast) }
        return out + [yolo, approvalButton]
    }

    var focusStops: Int { stopViews.count }

    func showFocus(_ stop: Int?) {
        let views = stopViews
        let focused = stop.flatMap { views.indices.contains($0) ? views[$0] : nil }
        bar.keyMarked = focused === bar
        fast.keyMarked = focused === fast
        yolo.keyMarked = focused === yolo
        approvalRing.isHidden = focused !== approvalButton
        setNeedsLayout()
    }

    func press(_ key: MacPickPanel.FootKey, at stop: Int) -> Bool {
        let views = stopViews
        guard views.indices.contains(stop) else { return false }
        switch (views[stop], key) {
        case (bar, .left): bar.step(-1)
        case (bar, .right): bar.step(1)
        case (fast, .space), (fast, .enter): fast.toggleFromKeyboard()
        case (yolo, .space), (yolo, .enter): yolo.toggleFromKeyboard()
        case (approvalButton, .space), (approvalButton, .enter):
            if approvalButton.isEnabled { approvalButton.performPrimaryAction() }
        default: return false
        }
        return true
    }

    // MARK: Layout

    private static let side: CGFloat = 8        // the card's inset from the panel's edges
    private static let inner: CGFloat = 14      // the words' inset inside the card
    private var rowH: CGFloat { (MacType.row.lineHeight + 18).rounded() }
    private var titleH: CGFloat { (MacType.row.lineHeight + 12).rounded() }
    private var factsH: CGFloat { (MacType.row.lineHeight + 14).rounded() }

    private var thinkingHeight: CGFloat {
        if state.efforts.isEmpty { return 0 }
        return titleH + (state.efforts.count > 1 ? MacThinkingSteps.height + 2 : 0)
    }

    func pieceHeight(width: CGFloat) -> CGFloat {
        let lineH = HQShape.pixel(traitCollection.displayScale)
        var card = thinkingHeight + rowH + lineH + rowH + 2
        if thinkingHeight > 0 { card += lineH }
        let offlineH = state.offline ? factsH - 6 : 0
        return Self.side + card + 2 + factsH + offlineH + 4
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        let lineH = HQShape.pixel(traitCollection.displayScale)
        let cardW = w - 2 * Self.side
        let inner = Self.inner
        var y: CGFloat = 0
        let wordsH = ceil(MacType.row.lineHeight)
        let showsThinking = !state.efforts.isEmpty
        thinkingTitle.isHidden = !showsThinking
        thinkingValue.isHidden = !showsThinking
        bar.isHidden = state.efforts.count < 2
        lines[0].isHidden = !showsThinking
        if showsThinking {
            y += 2
            let titleW = ceil(thinkingTitle.sizeThatFits(CGSize(width: cardW, height: wordsH)).width)
            let titleY = y + ((titleH - wordsH) / 2).rounded()
            thinkingTitle.frame = CGRect(x: inner, y: titleY, width: titleW, height: wordsH)
            let valueX = inner + titleW + 12
            thinkingValue.frame = CGRect(x: valueX, y: titleY, width: max(0, cardW - inner - valueX), height: wordsH)
            let cut = thinkingValue.intrinsicContentSize.width > thinkingValue.frame.width + 0.5
            valueTip.defaultToolTip = cut ? thinkingValue.attributedText?.string : nil
            y += titleH - 2
            if !bar.isHidden {
                bar.frame = CGRect(x: inner - 4, y: y, width: cardW - 2 * inner + 8, height: MacThinkingSteps.height)
                y += MacThinkingSteps.height + 2
            }
            lines[0].frame = CGRect(x: inner, y: y, width: cardW - inner, height: lineH)
            y += lineH
        }
        // Fast | YOLO: two halves with a short upright line between them.
        let half = (cardW / 2).rounded()
        fast.frame = CGRect(x: 0, y: y, width: half, height: rowH)
        yolo.frame = CGRect(x: half, y: y, width: cardW - half, height: rowH)
        lines[2].frame = CGRect(x: half, y: y + 8, width: lineH, height: rowH - 16)
        y += rowH
        lines[1].frame = CGRect(x: inner, y: y, width: cardW - inner, height: lineH)
        y += lineH
        // Approval Mode … all Otto chats ……… [Smart ⌃⌄]
        let iconSide = MacIcon.rowColumn
        approvalIcon.frame = CGRect(x: inner - 2, y: y + ((rowH - iconSide) / 2).rounded(), width: iconSide, height: iconSide)
        let nameX = approvalIcon.frame.maxX + 6
        let nameW = ceil(approvalName.sizeThatFits(CGSize(width: cardW, height: wordsH)).width)
        let buttonSize = approvalButton.sizeThatFits(CGSize(width: cardW / 2, height: rowH))
        let buttonW = ceil(buttonSize.width), buttonH = min(rowH - 8, ceil(buttonSize.height))
        approvalButton.frame = CGRect(x: cardW - 6 - buttonW, y: y + ((rowH - buttonH) / 2).rounded(), width: buttonW, height: buttonH)
        approvalRing.frame = approvalButton.frame.insetBy(dx: -2, dy: -2)
        let wordsY = y + ((rowH - wordsH) / 2).rounded()
        approvalName.frame = CGRect(x: nameX, y: wordsY, width: nameW, height: wordsH)
        // The note shows whole or not at all (orchestrator 2026-11-17: "all Hermes c…" read as broken); without it, the
        // pop-up's tooltip, its VoiceOver value and its menu's heading still say how far it reaches.
        let reachX = approvalName.frame.maxX + 8
        let reachRoom = approvalButton.frame.minX - 2 - reachX   // the pop-up's own 7 pt inset keeps the words apart
        let reachW = ceil(approvalReach.intrinsicContentSize.width)
        approvalReach.isHidden = reachW > reachRoom
        approvalReach.frame = CGRect(x: reachX, y: wordsY, width: min(reachW, max(0, reachRoom)), height: wordsH)
        y += rowH + 2
        card.frame = CGRect(x: Self.side, y: Self.side, width: cardW, height: y)
        // The facts, under the card; offline, the note over them.
        var fy = card.frame.maxY + 2
        if !offline.isHidden {
            offline.frame = CGRect(x: Self.side + 8, y: fy + 4, width: w - 2 * Self.side - 8, height: wordsH)
            fy += factsH - 6
        }
        facts.frame = CGRect(x: Self.side, y: fy, width: w - 2 * Self.side, height: factsH)
    }

    #if DEBUG
    var debugBar: MacThinkingSteps { bar }
    func debugOpenApprovals() { approvalButton.performPrimaryAction() }
    /// The Approval Mode pop-up's rows as it would open ("[Every chat with Otto]", "Smart ✓", …).
    func debugApprovalTitles() -> [String] {
        func titles(_ elements: [UIMenuElement]) -> [String] {
            elements.flatMap { element -> [String] in
                if let menu = element as? UIMenu { return (menu.title.isEmpty ? [] : ["[\(menu.title)]"]) + titles(menu.children) }
                return [element.title + ((element as? UIAction)?.state == .on ? " ✓" : "")]
            }
        }
        return titles(approvalItems())
    }
    #endif
}

/// One half of the Fast | YOLO row: its symbol, its name and a switch. A click on the switch (or Space with the
/// keyboard on it) flips it; dimmed, it says why in its tip.
final class MacSwitchHalf: UIView {
    var onChange: ((Bool) -> Void)?
    var on = false { didSet { if toggle.isOn != on { toggle.setOn(on, animated: window != nil && !HQMotion.reduced) } } }
    var supported = true { didSet { setNeedsLayout() } }
    var isEnabled = true { didSet { toggle.isEnabled = isEnabled; recolor() } }
    var warning = false { didSet { if warning != oldValue { recolor() } } }
    var keyMarked = false { didSet { ring.isHidden = !keyMarked } }
    var note: String? { didSet { toggle.accessibilityHint = note } }
    var tipText: String? { didSet { tip.defaultToolTip = tipText } }

    private let symbol: String
    private let icon = UIImageView()
    private let name = UILabel()
    private let toggle = UISwitch()
    private let ring = UIView()
    private let tip = UIToolTipInteraction()
    private static let scale: CGFloat = 0.75

    init(symbol: String, name title: String, identifier: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        icon.contentMode = .center
        icon.isAccessibilityElement = false
        name.text = title
        name.isAccessibilityElement = false
        toggle.accessibilityLabel = title
        toggle.accessibilityIdentifier = identifier
        toggle.preferredStyle = .sliding
        toggle.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.on = self.toggle.isOn
            self.onChange?(self.toggle.isOn)
        }, for: .valueChanged)
        ring.isUserInteractionEnabled = false
        ring.isHidden = true
        ring.layer.cornerCurve = .continuous
        for view in [icon, name, toggle, ring] as [UIView] { addSubview(view) }
        addInteraction(tip)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (half: MacSwitchHalf, _) in half.recolor() }
        recolor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func toggleFromKeyboard() {
        guard isEnabled else { return }
        on.toggle()
        onChange?(on)
    }

    private func recolor() {
        icon.image = UIImage(systemName: symbol)
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: MacType.row.pagesWeight(.semibold))
        icon.tintColor = warning ? ChatPalette.orange : ChatPalette.tint
        name.font = MacType.row
        name.textColor = ChatPalette.label
        toggle.onTintColor = Theme.inkSwitch ?? ChatPalette.tint   // [paper-ink], as the card's switches
        let alpha: CGFloat = isEnabled ? 1 : 0.45
        icon.alpha = alpha
        name.alpha = alpha
        ring.layer.borderColor = HQPalette.tint.resolvedColor(with: traitCollection).withAlphaComponent(Theme.isDesktop ? 1 : 0.6).cgColor
        ring.layer.borderWidth = HQShape.line(Theme.isDesktop ? 2 : 1.5)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        let iconSide = MacIcon.rowColumn
        icon.frame = CGRect(x: 12, y: ((h - iconSide) / 2).rounded(), width: iconSide, height: iconSide)
        // The Mac's small switch: the system's, at three quarters (a Mac switch beside 15 pt words, as drawn).
        let size = toggle.intrinsicContentSize
        let shown = CGSize(width: (size.width * Self.scale).rounded(), height: (size.height * Self.scale).rounded())
        toggle.transform = CGAffineTransform(scaleX: Self.scale, y: Self.scale)
        toggle.bounds = CGRect(origin: .zero, size: size)
        toggle.center = CGPoint(x: bounds.width - 12 - shown.width / 2, y: (h / 2).rounded())
        let switchFrame = CGRect(x: bounds.width - 12 - shown.width, y: ((h - shown.height) / 2).rounded(), width: shown.width, height: shown.height)
        toggle.isHidden = !supported
        let lineH = ceil(name.font.lineHeight)
        let x = icon.frame.maxX + 6
        name.frame = CGRect(x: x, y: ((h - lineH) / 2).rounded(), width: max(0, switchFrame.minX - 8 - x), height: lineH)
        ring.frame = switchFrame.insetBy(dx: -3, dy: -3)
        ring.layer.cornerRadius = ring.frame.height / 2
    }
}

/// The facts under the card in one quiet line ("1M context · 18% used · Included · 62% left ›"): a figure in the
/// label's ink, its words in the second grey. A part that opens a page underlines under the pointer and shows the
/// pointing hand; the chevron at the end belongs to the last part that opens one.
final class MacFactsLine: UIView {
    var parts: [ModelPanelModel.FactPart] = [] { didSet { if parts != oldValue { rebuild() } } }
    var opens: [String: (name: String, open: () -> Void)] = [:] { didSet { rebuild() } }
    var isEnabled = true { didSet { if isEnabled != oldValue { rebuild() } } }

    private var buttons: [UIButton] = []
    private var dots: [UILabel] = []
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.forward"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        chevron.contentMode = .center
        addSubview(chevron)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (line: MacFactsLine, _) in line.rebuild() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func text(_ part: ModelPanelModel.FactPart, underline: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var figure: [NSAttributedString.Key: Any] = [.font: MacType.row.pagesWeight(.semibold), .foregroundColor: ChatPalette.label]
        var words: [NSAttributedString.Key: Any] = [.font: MacType.row, .foregroundColor: ChatPalette.label2]
        if underline {
            figure[.underlineStyle] = NSUnderlineStyle.single.rawValue
            words[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if !part.figure.isEmpty { out.append(NSAttributedString(string: part.figure, attributes: figure)) }
        out.append(NSAttributedString(string: part.words, attributes: words))
        return out
    }

    private func rebuild() {
        buttons.forEach { $0.removeFromSuperview() }
        dots.forEach { $0.removeFromSuperview() }
        buttons = []
        dots = []
        for (i, part) in parts.enumerated() {
            let page = isEnabled ? opens[part.title] : nil
            let button = FactButton()
            button.clipsToBounds = true
            button.setAttributedTitle(text(part, underline: false), for: .normal)
            button.underlined = { [weak self] on in self?.text(part, underline: on) }
            button.isUserInteractionEnabled = page != nil
            button.accessibilityLabel = part.spoken
            button.accessibilityIdentifier = "model.panel.fact.\(part.title == ModelPanelState.Fact.contextTitle ? "context" : part.title.lowercased().replacingOccurrences(of: " ", with: "-"))"
            if let page {
                button.accessibilityTraits = .button
                button.accessibilityHint = "Opens \(page.name)"
                button.toolTip = page.name
                button.addAction(UIAction { _ in page.open() }, for: .primaryActionTriggered)
            } else {
                button.accessibilityTraits = .staticText
            }
            addSubview(button)
            buttons.append(button)
            if i < parts.count - 1 {
                let dot = UILabel()
                dot.text = "·"
                dot.font = MacType.row
                dot.textColor = ChatPalette.label3
                dot.isAccessibilityElement = false
                addSubview(dot)
                dots.append(dot)
            }
        }
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: HQFont.preferred(.footnote).pagesWeight(.semibold))
        chevron.tintColor = ChatPalette.label3
        chevron.isHidden = !(parts.last.map { isEnabled && opens[$0.title] != nil } ?? false)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        let room = bounds.width - 8 - (chevron.isHidden ? 0 : 16)
        // Too long for one line (a large UI Scale, a long price): the share used goes first, then the price, never a
        // part cut or run into the next one. Each dropped fact is still on the page it would have opened.
        let dotW = dots.first.map { ceil($0.intrinsicContentSize.width) + 12 } ?? 0
        var shown = Array(buttons.indices)
        func width(_ indices: [Int]) -> CGFloat {
            8 + indices.reduce(0) { $0 + ceil(buttons[$1].intrinsicContentSize.width) } + CGFloat(max(0, indices.count - 1)) * dotW
        }
        for drop in ["Context used", "Price", ModelPanelState.Fact.contextTitle] where width(shown) > room {
            if let at = parts.firstIndex(where: { $0.title == drop }) { shown.removeAll { $0 == at } }
        }
        var x: CGFloat = 8
        for (i, button) in buttons.enumerated() {
            button.isHidden = !shown.contains(i)
            if i < dots.count { dots[i].isHidden = true }
            guard !button.isHidden else { continue }
            let size = button.intrinsicContentSize
            let w = min(ceil(size.width), max(0, room - x))
            button.frame = CGRect(x: x, y: ((h - size.height) / 2).rounded(), width: w, height: ceil(size.height))
            x += w
            if i < dots.count, i != shown.last {
                let dw = ceil(dots[i].intrinsicContentSize.width)
                dots[i].isHidden = false
                dots[i].frame = CGRect(x: x + 6, y: button.frame.minY, width: dw, height: button.frame.height)
                x += dw + 12
            }
        }
        let side: CGFloat = 14
        chevron.frame = CGRect(x: min(x + 4, bounds.width - side - 2), y: ((h - side) / 2).rounded(), width: side, height: side)
    }

    #if DEBUG
    func debugOpen(_ title: String) { if let page = opens[title], isEnabled { page.open() } }
    #endif

    /// A fact that opens its page: underlined under the pointer, the pointing hand, a dim while pressed.
    private final class FactButton: UIButton {
        var underlined: ((Bool) -> NSAttributedString?)?
        override init(frame: CGRect) {
            super.init(frame: frame)
            titleLabel?.lineBreakMode = .byTruncatingTail
            MacHover.drawsOwnHover(self)
            addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
            guard isUserInteractionEnabled else { return }
            let on = recognizer.state == .began || recognizer.state == .changed
            if let text = underlined?(on) { setAttributedTitle(text, for: .normal) }
            MacWindow.cursor(on ? "pointingHandCursor" : "arrowCursor")
        }
        override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.6 : 1 } }
    }
}
#endif
