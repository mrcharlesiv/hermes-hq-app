import UIKit

// The cell for prompt rows (spec 1x §4.2, §4.4): the approval card (solid, hairline edge, capsule buttons, a countdown
// updated in place once a second) and the question card (the same shell: a header glyph, answer marks, hairlines
// between questions). Every frame comes from `PromptRowLayout`.

/// What the chat screen does for a prompt cell (ChatViewController adopts it; App/Questions/ChatPromptsController).
@MainActor protocol ChatPromptCellHandling: AnyObject {
    func promptCard(_ id: String, tapped button: ApprovalButton)
    func promptCardShowAll(_ id: String)
    /// The countdown for a card ("Expires within 4 min"), read every second.
    func promptExpiryLabel(clockKey: String, firstSeen: Date) -> String
    /// [drafts] Send, Edit or Don't Send on a draft card, and its Show All / Show Less.
    func draftCard(_ draft: DraftCardRow, tapped button: DraftButton)
    func draftCardToggle(rowId: String)
    /// The conversation a draft answers, whole, in a sheet.
    func draftCardThread(_ draft: DraftCardRow)
}

final class ChatPromptCell: ChatBaseCell {
    static let reuse = "prompt"
    private let card = UIView()
    private var textViews: [TextDrawView] = []
    private var symbols: [PromptSymbol] = []
    private var symbolViews: [UIImageView] = []
    private var ruleViews: [UIView] = []
    private let icon = UIImageView()
    private let expiry = UILabel()
    private let showAll = UIControl()
    private var buttons: [ApprovalButton: UIButton] = [:]
    private var approval: ApprovalCardRow?
    private var draft: DraftCardRow?                         // [drafts]
    private var draftButtons: [DraftButton: UIButton] = [:]
    private let paper = UIView()                             // the panel a draft's words sit on
    private let quote = UIView()                             // the bar beside the conversation a draft answers
    private let threadToggle = UIControl()
    private var ticker: Timer?
    private var baseAccessibility = ""

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        card.layer.cornerRadius = ChatMetrics.insetCardRadius
        card.layer.cornerCurve = .continuous
        card.isAccessibilityElement = true
        contentView.addSubview(card)
        paper.isUserInteractionEnabled = false; paper.isHidden = true
        paper.layer.cornerRadius = 12; paper.layer.cornerCurve = .continuous
        card.addSubview(paper)
        quote.isUserInteractionEnabled = false; quote.isHidden = true
        quote.layer.cornerRadius = 1.5
        card.addSubview(quote)
        threadToggle.isHidden = true
        threadToggle.isAccessibilityElement = true
        threadToggle.accessibilityTraits = .button
        threadToggle.accessibilityIdentifier = "draft.thread"
        threadToggle.addAction(UIAction { [weak self] _ in
            guard let self, let draft = self.draft else { return }
            self.handler?.draftCardThread(draft)
        }, for: .touchUpInside)
        contentView.addSubview(threadToggle)
        icon.image = UIImage(systemName: "apple.terminal")
        icon.tintColor = ChatPalette.label2
        icon.contentMode = .scaleAspectFit
        icon.isAccessibilityElement = false
        contentView.addSubview(icon)
        expiry.textAlignment = .right
        expiry.textColor = ChatPalette.label2   // [a11y] how long is left is read, not decoration
        expiry.adjustsFontForContentSizeCategory = false
        expiry.accessibilityIdentifier = "approval.expiry"
        expiry.isAccessibilityElement = false
        contentView.addSubview(expiry)
        showAll.addTarget(self, action: #selector(showAllTapped), for: .touchUpInside)
        showAll.accessibilityLabel = "Show All"
        showAll.accessibilityTraits = .button
        showAll.isAccessibilityElement = true
        contentView.addSubview(showAll)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (cell: ChatPromptCell, _) in
            cell.updateBorder()
            cell.placeSymbols(cell.symbols)   // the picked mark's palette colours are resolved into its image
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var handler: ChatPromptCellHandling? { delegate as? ChatPromptCellHandling }

    override func prepareForReuse() {
        super.prepareForReuse()
        card.layer.removeAllAnimations()
        contentView.alpha = 1
        approval = nil
        draft = nil
        stopTicking()
    }

    override func configure(_ row: ChatRow, layout: RowLayout) {
        super.configure(row, layout: layout)
        guard case .prompt(let l) = layout.content, case .prompt(let spec) = row.kind else { return }
        // Text pieces.
        while textViews.count < l.texts.count {
            let v = TextDrawView()
            v.isAccessibilityElement = false
            contentView.insertSubview(v, aboveSubview: card)
            textViews.append(v)
        }
        for (i, v) in textViews.enumerated() {
            if i < l.texts.count {
                v.isHidden = false
                v.frame = l.texts[i].frame
                v.set(layout: l.texts[i].text)
            } else {
                v.isHidden = true
                v.set(layout: nil)
            }
        }
        if let frame = l.cardFrame {
            card.isHidden = false
            card.frame = frame
            card.backgroundColor = ChatPalette.botBubble   // every card: a reply bubble's fill, no edge
            let panel = l.draft?.paper ?? l.approval?.paper
            paper.isHidden = panel == nil
            if let p = panel {
                paper.frame = p.offsetBy(dx: -frame.minX, dy: -frame.minY)
                paper.backgroundColor = ChatPalette.page
            }
            quote.isHidden = l.draft?.quote == nil
            if let q = l.draft?.quote {
                quote.frame = q.offsetBy(dx: -frame.minX, dy: -frame.minY)
                quote.backgroundColor = ChatPalette.tint.withAlphaComponent(0.55)
            }
        } else {
            card.isHidden = true
        }
        placeSymbols(l.symbols)
        placeRules(l.rules)
        baseAccessibility = l.accessibility

        guard case .approval(let a) = spec.kind, let al = l.approval else {
            approval = nil
            updateBorder()
            icon.isHidden = true
            expiry.isHidden = true
            buttons.values.forEach { $0.isHidden = true }
            card.accessibilityLabel = l.accessibility
            stopTicking()
            if case .draft(let d) = spec.kind, let dl = l.draft {
                configureDraft(d, dl)
            } else {
                draft = nil
                showAll.isHidden = true
                threadToggle.isHidden = true
                draftButtons.values.forEach { $0.isHidden = true }
                card.accessibilityIdentifier = "clarify.note"
                contentView.accessibilityElements = [card]
            }
            return
        }
        draft = nil
        draftButtons.values.forEach { $0.isHidden = true }
        threadToggle.isHidden = true
        showAll.accessibilityLabel = "Show All"
        let wasLeaving = approval?.id == a.id && approval?.leaving == true
        approval = a
        updateBorder()
        card.accessibilityIdentifier = "approval.card"
        icon.isHidden = al.iconFrame.isEmpty   // the header's round mark stands for it
        icon.frame = al.iconFrame
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: al.iconFrame.height * 0.85, weight: .regular)
        expiry.isHidden = false
        expiry.frame = al.expiryFrame
        expiry.font = al.expiryFont
        expiry.textAlignment = al.expiryLeading ? .natural : .right
        showAll.isHidden = al.showAllFrame == nil
        showAll.frame = al.showAllFrame ?? .zero
        var shown = Set<ApprovalButton>()
        var ordered: [UIButton] = []
        for (kind, frame) in al.buttons {
            let button = buttons[kind] ?? makeButton(kind)
            buttons[kind] = button
            button.isHidden = false
            button.frame = frame
            button.configuration = config(kind, font: al.buttonFont, answering: a.answering.map { matches(kind, $0) } ?? false)
            button.isEnabled = a.answering == nil || matches(kind, a.answering!)
            button.isUserInteractionEnabled = a.answering == nil && !a.leaving
            if kind == .more { button.menu = moreMenu(a) }
            shown.insert(kind)
            ordered.append(button)
        }
        for (kind, button) in buttons where !shown.contains(kind) { button.isHidden = true }
        // VoiceOver: the card reads as one element, then its buttons (the stacked layout lists Run first).
        contentView.accessibilityElements = [card] + (al.showAllFrame != nil ? [showAll] : []) + (al.stacked ? ordered : ordered.reversed())
        updateExpiry()
        if window != nil { startTicking() }
        // Answered: the card fades out (200 ms) before its row goes.
        if a.leaving && !wasLeaving {
            if HQMotion.reduced { contentView.alpha = 0 } else {
                UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState]) { self.contentView.alpha = 0 }
            }
        } else if !a.leaving {
            contentView.alpha = 1
        }
    }

    /// The Run / Reject row, in `view`'s coordinates (L422: the jump capsule's landing); nil when this cell is not an approval.
    func actionsRect(in view: UIView) -> CGRect? {
        guard approval != nil else { return nil }
        let shown = buttons.values.filter { !$0.isHidden }
        guard !shown.isEmpty else { return nil }
        return shown.map { view.convert($0.bounds, from: $0) }.reduce(CGRect.null) { $0.union($1) }
    }

    private func matches(_ button: ApprovalButton, _ choice: ApprovalChoice) -> Bool {
        switch (button, choice) {
        case (.run, .once), (.reject, .deny), (.dismiss, .deny), (.session, .session), (.always, .always): true
        case (.more, .session), (.more, .always): true
        default: false
        }
    }

    private func updateBorder() {
        let hair = 1 / max(1, traitCollection.displayScale)
        card.layer.borderWidth = 0
        for rule in ruleViews where rule.bounds.height != hair { rule.frame.size.height = hair }
    }

    private func placeSymbols(_ symbols: [PromptSymbol]) {
        self.symbols = symbols
        while symbolViews.count < symbols.count {
            let v = UIImageView()
            v.contentMode = .scaleAspectFit
            v.isAccessibilityElement = false
            contentView.insertSubview(v, aboveSubview: card)
            symbolViews.append(v)
        }
        for (i, v) in symbolViews.enumerated() {
            guard i < symbols.count else { v.isHidden = true; v.image = nil; continue }
            let symbol = symbols[i]
            v.isHidden = false
            v.frame = symbol.frame
            var config = UIImage.SymbolConfiguration(pointSize: symbol.frame.height * 0.86,
                                                     weight: symbol.style == .header ? .semibold : .regular)
            switch symbol.style {
            case .header: v.tintColor = ChatPalette.label2
            case .blank: v.tintColor = ChatPalette.label3
            case .dim:
                config = config.applying(UIImage.SymbolConfiguration(paletteColors: [.white, ChatPalette.label3]))
                v.tintColor = ChatPalette.label3
            case .picked:
                // The dock's picked mark: a tint disc with a white check.
                config = config.applying(UIImage.SymbolConfiguration(paletteColors: [.white, ChatPalette.tint]))
                v.tintColor = ChatPalette.tint
            }
            v.image = UIImage(systemName: symbol.name, withConfiguration: config)
        }
    }

    private func placeRules(_ rules: [CGRect]) {
        while ruleViews.count < rules.count {
            let v = UIView()
            v.backgroundColor = ChatPalette.separator
            v.isUserInteractionEnabled = false
            contentView.insertSubview(v, aboveSubview: card)
            ruleViews.append(v)
        }
        let hair = 1 / max(1, traitCollection.displayScale)
        for (i, v) in ruleViews.enumerated() {
            v.isHidden = i >= rules.count
            if i < rules.count { v.frame = CGRect(x: rules[i].minX, y: rules[i].minY, width: rules[i].width, height: hair) }
        }
    }

    private func makeButton(_ kind: ApprovalButton) -> UIButton {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "approval.\(kind)"
        if kind == .more {
            button.showsMenuAsPrimaryAction = true
        } else {
            button.addAction(UIAction { [weak self] _ in self?.tapped(kind) }, for: .primaryActionTriggered)
        }
        contentView.addSubview(button)
        return button
    }

    private func config(_ kind: ApprovalButton, font: UIFont, answering: Bool) -> UIButton.Configuration {
        var c: UIButton.Configuration
        switch kind {
        case .run:
            c = .filled()
            c.baseBackgroundColor = ChatPalette.tint
            c.baseForegroundColor = .white
        case .more, .session, .always:
            c = .filled()
            c.baseBackgroundColor = ChatPalette.fill2
            c.baseForegroundColor = ChatPalette.label
        case .reject, .dismiss:
            c = .plain()
            c.baseForegroundColor = ChatPalette.label2
        }
        c.cornerStyle = .capsule
        c.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
        c.title = PromptLayout.buttonTitle(kind)
        c.titleLineBreakMode = .byTruncatingTail
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = font
            return a
        }
        if kind == .more {
            c.image = UIImage(systemName: "chevron.down",
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: font.pointSize * 0.7, weight: .semibold))
            c.imagePlacement = .trailing
            c.imagePadding = 6
        }
        c.showsActivityIndicator = answering
        if answering { c.title = nil; c.image = nil }
        return c
    }

    private func moreMenu(_ a: ApprovalCardRow) -> UIMenu {
        // No Reject in the menu on touch (fe-convo-gates.ts:483).
        var items: [UIMenuElement] = []
        if a.allowSession {
            items.append(UIAction(title: PromptLayout.buttonTitle(.session)) { [weak self] _ in self?.tapped(.session) })
        }
        if a.allowAlways {
            items.append(UIAction(title: PromptLayout.buttonTitle(.always)) { [weak self] _ in self?.tapped(.always) })
        }
        return UIMenu(children: items)
    }

    private func tapped(_ kind: ApprovalButton) {
        guard let a = approval, a.answering == nil, !a.leaving else { return }
        handler?.promptCard(a.id, tapped: kind)
    }

    @objc private func showAllTapped() {
        if let draft { handler?.draftCardToggle(rowId: draft.rowId); return }
        guard let a = approval else { return }
        handler?.promptCardShowAll(a.id)
    }

    // MARK: Draft card ([drafts])

    private func configureDraft(_ d: DraftCardRow, _ dl: DraftCardLayout) {
        draft = d
        card.accessibilityIdentifier = "draft.card"
        showAll.isHidden = dl.showAllFrame == nil
        showAll.frame = dl.showAllFrame ?? .zero
        showAll.accessibilityLabel = dl.showAllTitle
        threadToggle.isHidden = dl.threadFrame == nil
        threadToggle.frame = dl.threadFrame ?? .zero
        threadToggle.accessibilityLabel = dl.threadTitle
        var shown = Set<DraftButton>()
        var ordered: [UIButton] = []
        for (kind, frame) in dl.buttons {
            let button = draftButtons[kind] ?? makeDraftButton(kind)
            draftButtons[kind] = button
            button.isHidden = false
            button.frame = frame
            button.configuration = draftConfig(kind, font: dl.buttonFont)
            button.isEnabled = !d.editing
            shown.insert(kind)
            ordered.append(button)
        }
        for (kind, button) in draftButtons where !shown.contains(kind) { button.isHidden = true }
        // VoiceOver: the card, the conversation's button, Show All, then its buttons with Send first.
        let links: [UIView] = (dl.threadFrame != nil ? [threadToggle] : []) + (dl.showAllFrame != nil ? [showAll] : [])
        contentView.accessibilityElements = [card] + links + (dl.stacked ? ordered : ordered.reversed())
    }

    private func makeDraftButton(_ kind: DraftButton) -> UIButton {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "draft.\(kind)"
        button.addAction(UIAction { [weak self] _ in
            guard let self, let draft = self.draft, draft.state == .waiting, !draft.editing else { return }
            self.handler?.draftCard(draft, tapped: kind)
        }, for: .primaryActionTriggered)
        contentView.addSubview(button)
        return button
    }

    private func draftConfig(_ kind: DraftButton, font: UIFont) -> UIButton.Configuration {
        var c: UIButton.Configuration
        switch kind {
        case .send:
            c = .filled()
            c.baseBackgroundColor = ChatPalette.tint
            c.baseForegroundColor = .white
        case .edit:
            c = .filled()
            c.baseBackgroundColor = ChatPalette.fill2
            c.baseForegroundColor = ChatPalette.label
        case .skip:
            c = .plain()
            c.baseForegroundColor = ChatPalette.label2
        }
        c.cornerStyle = .capsule
        c.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
        c.title = PromptLayout.draftButtonTitle(kind)
        c.titleLineBreakMode = .byTruncatingTail
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = font
            return a
        }
        return c
    }

    // MARK: Countdown (in place, no re-measure)

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, approval != nil { startTicking() } else { stopTicking() }
    }

    private func startTicking() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateExpiry() } }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func updateExpiry() {
        guard let a = approval else { return }
        let label = handler?.promptExpiryLabel(clockKey: a.clockKey, firstSeen: a.firstSeen) ?? ""
        if expiry.text != label { expiry.text = label }
        card.accessibilityLabel = label.isEmpty ? baseAccessibility : "\(baseAccessibility). \(label)"
    }
}
