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
    /// [questions] Answer Now on a question that went without an answer.
    func clarifyCardAnswer(_ card: SettledClarifyCard)
    /// [shopping] A product card opens its page; the one product's Buy / Notify Me, a follow-up, See All; an order's
    /// Cancel or Pay (App/Shopping/ChatViewController+Shopping.swift).
    func shoppingOpen(_ card: ProductsCardRow, index: Int)
    func shoppingAsk(_ card: ProductsCardRow, index: Int, ask: ShoppingCards.Ask)
    func shoppingFollowUp(_ card: ProductsCardRow, text: String)
    func orderCard(_ card: OrderCardRow, tapped answer: ShoppingCards.OrderAnswer)
    func orderCard(_ card: OrderCardRow, openedItem index: Int)
    /// [travel] Flight and hotel cards: detail sheets, booking/watch asks, follow-ups (App/Travel/ChatViewController+Travel.swift).
    func travelOpenFlight(_ card: FlightsCardRow, index: Int)
    func travelAskFlight(_ card: FlightsCardRow, index: Int, ask: TravelCards.Ask)
    func travelOpenHotel(_ card: HotelsCardRow, index: Int)
    func travelAskHotel(_ card: HotelsCardRow, index: Int, ask: TravelCards.Ask)
    func travelFollowUp(rowId: String, text: String)
    /// [asks] An ask card's choice, its "Something else…" and its link (App/Asks/ChatViewController+Asks.swift).
    func askCard(_ card: AskCardRow, chose index: Int)
    func askCardOther(_ card: AskCardRow)
    func askCardOpen(_ card: AskCardRow)
    /// [asks v2] A picked choice's ready reply: Send or Edit.
    func askCardReply(_ card: AskCardRow, tapped button: DraftButton)
}

extension ChatPromptCellHandling {
    func orderCard(_ card: OrderCardRow, openedItem index: Int) {}
    func travelOpenFlight(_ card: FlightsCardRow, index: Int) {}
    func travelAskFlight(_ card: FlightsCardRow, index: Int, ask: TravelCards.Ask) {}
    func travelOpenHotel(_ card: HotelsCardRow, index: Int) {}
    func travelAskHotel(_ card: HotelsCardRow, index: Int, ask: TravelCards.Ask) {}
    func travelFollowUp(rowId: String, text: String) {}
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
    private let paper = UIView()                             // the panel an approval or ask card's words sit on
    private let quote = UIView()                             // the bar beside the conversation a draft answers
    private let bodyBar = UIView()                           // [calm-chat] left accent bar / receipt stem for drafts
    private let draftDivider = UIView()                      // [calm-chat] subtle hairline above waiting draft buttons
    private let draftToggle = UIControl()                    // [calm-chat] tap target to expand/collapse folded drafts & settled clarifies
    private var toggleRowId: String?                         // [calm-chat] rowId targeted by `draftToggle`
    private let threadToggle = UIControl()
    private var settled: SettledClarifyCard?                 // [questions] a settled question card
    private let answerNow = UIButton(type: .system)
    private var ticker: Timer?
    /// [shopping] The product cards' view and the order card's buttons, made on first use (ChatPromptCell+Shopping.swift).
    var shoppingViews = ShoppingCellViews()
    /// [travel] The flight and hotel cards' views, made on first use (App/Travel/ChatPromptCell+Travel.swift).
    var travelViews = TravelCellViews()
    /// [asks] The ask card's view, made on first use (App/Asks/ChatPromptCell+Asks.swift).
    var askViews = AskCellViews()
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
        bodyBar.isUserInteractionEnabled = false; bodyBar.isHidden = true
        bodyBar.layer.cornerRadius = 1.25
        card.addSubview(bodyBar)
        draftDivider.isUserInteractionEnabled = false; draftDivider.isHidden = true
        draftDivider.backgroundColor = ChatPalette.separator
        card.addSubview(draftDivider)
        draftToggle.isHidden = true
        draftToggle.isAccessibilityElement = true
        draftToggle.accessibilityTraits = .button
        draftToggle.accessibilityIdentifier = "draft.toggle"
        draftToggle.addAction(UIAction { [weak self] _ in
            guard let self, let id = self.toggleRowId else { return }
            Haptics.play(.selection)
            self.handler?.draftCardToggle(rowId: id)
        }, for: .touchUpInside)
        contentView.addSubview(draftToggle)
        PointerEffects.surface(draftToggle)
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
        answerNow.isHidden = true
        answerNow.accessibilityIdentifier = "clarify.answerNow"
        answerNow.addAction(UIAction { [weak self] _ in
            guard let self, let card = self.settled, card.answerable else { return }
            self.handler?.clarifyCardAnswer(card)
        }, for: .primaryActionTriggered)
        contentView.addSubview(answerNow)
        #if targetEnvironment(macCatalyst)
        // [Mac AAA 2026-11-16] The card's buttons answer the pointer: the transcript is left out of `PointerEffects`' sweep.
        PointerEffects.button(answerNow)
        // [hover-shape] Tight outline around the drawn link line, never the full 44 pt touch target.
        for linkControl in [showAll, threadToggle] {
            PointerEffects.outline(linkControl) { [weak linkControl] in
                guard let box = linkControl?.bounds, box.width > 0, box.height > 0 else { return nil }
                let h = min(box.height, 24)
                let rect = CGRect(x: 0, y: ((box.height - h) / 2).rounded(), width: box.width, height: h)
                return PointerEffects.Outline(rect: rect, radius: HQShape.radius(6, .control), strong: false)
            }
        }
        #endif
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (cell: ChatPromptCell, _) in
            cell.updateBorder()
            cell.placeSymbols(cell.symbols)   // the picked mark's palette colours are resolved into its image
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var handler: ChatPromptCellHandling? { delegate as? ChatPromptCellHandling }

    override func prepareForReuse() {
        super.prepareForReuse()
        card.layer.removeAllAnimations()
        contentView.alpha = 1
        approval = nil
        draft = nil
        toggleRowId = nil
        settled = nil
        stopTicking()
        resetShopping()   // [shopping]
        resetTravel()     // [travel]
        resetAsk()        // [asks]
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
            card.layer.cornerRadius = ChatMetrics.insetCardRadius
            card.backgroundColor = ChatPalette.promptCard
            // [calm-chat] Draft and ask cards render single-surface with an accent bar instead of a nested bordered box.
            let panel = (l.draft != nil || l.ask != nil) ? nil : l.approval?.paper
            paper.isHidden = panel == nil
            if let p = panel {
                paper.frame = p.offsetBy(dx: -frame.minX, dy: -frame.minY)
                paper.layer.cornerRadius = HQShape.radius(12, .card)
                paper.backgroundColor = ChatPalette.page
            }
            quote.isHidden = l.draft?.quote == nil
            if let q = l.draft?.quote {
                quote.frame = q.offsetBy(dx: -frame.minX, dy: -frame.minY)
                quote.backgroundColor = ChatPalette.separator
            }
            bodyBar.isHidden = l.draft?.bodyBar == nil
            if let bar = l.draft?.bodyBar {
                bodyBar.frame = bar.offsetBy(dx: -frame.minX, dy: -frame.minY)
                bodyBar.backgroundColor = (l.draft?.bodyBarTint == true)
                    ? ChatPalette.tint.withAlphaComponent(0.55)
                    : ChatPalette.separator
            }
            draftDivider.isHidden = l.draft?.footerDivider == nil
            if let div = l.draft?.footerDivider {
                let hair = HQShape.pixel(traitCollection.displayScale)
                draftDivider.frame = CGRect(x: div.minX - frame.minX, y: div.minY - frame.minY, width: div.width, height: hair)
                draftDivider.backgroundColor = ChatPalette.separator.withAlphaComponent(0.55)
            }
        } else {
            card.isHidden = true
            paper.isHidden = true
            quote.isHidden = true
            bodyBar.isHidden = true
            draftDivider.isHidden = true
        }
        let backing = l.draft?.backingFrame ?? l.ask?.backingFrame ?? l.foldToggle?.backingFrame
        placeBacking(backing, radius: min(16, (backing?.height ?? 0) / 2))
        placeSymbols(l.symbols)
        placeRules(l.rules)
        baseAccessibility = l.accessibility
        configureAnswerNow(spec, l)
        configureShopping(spec, l)   // [shopping]
        configureTravel(spec, l)     // [travel]
        configureAsk(spec, l)        // [asks]

        guard case .approval(let a) = spec.kind, let al = l.approval else {
            approval = nil
            updateBorder()
            icon.isHidden = true
            expiry.isHidden = true
            buttons.values.forEach { $0.isHidden = true }
            card.accessibilityLabel = l.accessibility
            stopTicking()
            if case .draft(let d) = spec.kind, let dl = l.draft {
                configureDraft(d, dl, hasCard: l.cardFrame != nil)
            } else {
                draft = nil
                showAll.isHidden = true
                threadToggle.isHidden = true
                draftButtons.values.forEach { $0.isHidden = true }
                if let ft = l.foldToggle {
                    toggleRowId = ft.rowId
                    draftToggle.isHidden = false
                    draftToggle.frame = ft.frame
                    draftToggle.accessibilityIdentifier = "clarify.toggle"
                    draftToggle.accessibilityLabel = ft.label
                    draftToggle.accessibilityValue = ft.expanded ? "Expanded" : "Collapsed"
                    draftToggle.layer.cornerRadius = 8
                    PointerEffects.outlineDidLayout(draftToggle)
                    card.accessibilityIdentifier = "clarify.note"
                    contentView.accessibilityElements = l.cardFrame != nil
                        ? [draftToggle, card] + (answerNow.isHidden ? [] : [answerNow])
                        : [draftToggle]
                } else {
                    toggleRowId = nil
                    draftToggle.isHidden = true
                    card.accessibilityIdentifier = "clarify.note"
                    contentView.accessibilityElements = shoppingAccessibility(card: card)   // [shopping]
                        ?? travelAccessibility()                                           // [travel]
                        ?? askAccessibility(card: card)                                    // [asks]
                        ?? ([card] + (answerNow.isHidden ? [] : [answerNow]))
                }
            }
            return
        }
        draft = nil
        toggleRowId = nil
        draftToggle.isHidden = true
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
        PointerEffects.outlineDidLayout(showAll)
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
                UIView.animate(withDuration: HQMotion.fade, delay: 0, options: [.beginFromCurrentState]) { self.contentView.alpha = 0 }
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
        let hair = HQShape.pixel(traitCollection.displayScale)
        // [cards] Every standalone prompt card (drafts, approvals, asks, orders, questions) carries a crisp edge.
        let edge = ChatPalette.promptEdge.resolvedColor(with: traitCollection)
        card.layer.borderColor = edge.cgColor
        card.layer.borderWidth = edge.cgColor.alpha > 0 ? max(hair, 1) : 0
        // Inset draft / command / reply panel: a hairline edge keeps it distinct inside the card in every theme.
        let panelEdge = ChatPalette.separator.resolvedColor(with: traitCollection)
        paper.layer.borderColor = panelEdge.cgColor
        paper.layer.borderWidth = panelEdge.cgColor.alpha > 0 ? hair : 0
        for rule in ruleViews where rule.bounds.height != hair { rule.frame.size.height = hair }
        if !draftDivider.isHidden && draftDivider.bounds.height != hair { draftDivider.frame.size.height = hair }
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
            // [paper-ink] A filled mark's glyph (the ?, the –) is drawn in the card's own colour, never left to the
            // system: on Paper's black card in dark the ? came out faint on its light disc (owner 2026-11-16, "the
            // question card looks odd"). In an ink skin the dim mark's glyph is the card's too (white vanished on it).
            let cardInk = ChatPalette.promptCard
            switch symbol.style {
            case .header:
                config = config.applying(UIImage.SymbolConfiguration(paletteColors: [cardInk, ChatPalette.label2]))
                v.tintColor = ChatPalette.label2
            case .blank: v.tintColor = ChatPalette.label3
            case .dim:
                config = config.applying(UIImage.SymbolConfiguration(paletteColors: [Theme.inkIcons != nil ? cardInk : .white, ChatPalette.label3]))
                v.tintColor = ChatPalette.label3
            case .picked:
                // The dock's picked mark: a tint disc with a white check.
                config = config.applying(UIImage.SymbolConfiguration(paletteColors: [ChatPalette.onTint, ChatPalette.tint]))
                v.tintColor = ChatPalette.tint
            case .quiet:
                v.tintColor = ChatPalette.label2
            case .success:
                let checkInk = traitCollection.userInterfaceStyle == .dark ? cardInk : UIColor.white
                config = config.applying(UIImage.SymbolConfiguration(paletteColors: [checkInk, ChatPalette.green]))
                v.tintColor = ChatPalette.green
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
        let hair = HQShape.pixel(traitCollection.displayScale)
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
        #if targetEnvironment(macCatalyst)
        PointerEffects.button(button)   // [Mac AAA 2026-11-16] the transcript is left out of `PointerEffects`' sweep
        #endif
        return button
    }

    private func config(_ kind: ApprovalButton, font: UIFont, answering: Bool) -> UIButton.Configuration {
        var c: UIButton.Configuration
        switch kind {
        case .run:
            c = .filled()
            c.baseBackgroundColor = ChatPalette.tint
            c.baseForegroundColor = ChatPalette.onTint   // [paper-ink]
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

    // MARK: Answer Now ([questions])

    /// A settled question card with a question left unanswered: Answer Now, a tint capsule at the card's trailing foot.
    private func configureAnswerNow(_ spec: PromptRow, _ l: PromptRowLayout) {
        guard case .settled(let card) = spec.kind, let frame = l.answerNow, let font = l.answerNowFont else {
            settled = nil
            answerNow.isHidden = true
            return
        }
        settled = card
        answerNow.isHidden = false
        answerNow.frame = frame
        var c = UIButton.Configuration.filled()
        c.baseBackgroundColor = ChatPalette.tint
        c.baseForegroundColor = ChatPalette.onTint   // [paper-ink] read on Paper's ivory accent in dark
        c.cornerStyle = .capsule
        c.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
        c.title = PromptLayout.answerNowTitle
        c.titleLineBreakMode = .byTruncatingTail
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = font
            return a
        }
        answerNow.configuration = c
        answerNow.accessibilityHint = card.rows.count == 1 ? "Answers the question now, in the chat" : "Answers the questions now, in the chat"
    }

    // MARK: Draft card ([drafts])

    private func configureDraft(_ d: DraftCardRow, _ dl: DraftCardLayout, hasCard: Bool) {
        draft = d
        card.accessibilityIdentifier = "draft.card"
        showAll.isHidden = dl.showAllFrame == nil
        showAll.frame = dl.showAllFrame ?? .zero
        showAll.accessibilityLabel = dl.showAllTitle
        PointerEffects.outlineDidLayout(showAll)
        threadToggle.isHidden = dl.threadFrame == nil
        threadToggle.frame = dl.threadFrame ?? .zero
        threadToggle.accessibilityLabel = dl.threadTitle
        PointerEffects.outlineDidLayout(threadToggle)
        if let toggle = dl.toggleFrame {
            toggleRowId = d.rowId
            draftToggle.isHidden = false
            draftToggle.frame = toggle
            draftToggle.accessibilityIdentifier = "draft.toggle"
            draftToggle.accessibilityLabel = dl.toggleLabel
            draftToggle.accessibilityValue = dl.toggleExpanded ? "Expanded" : "Collapsed"
            if hasCard && !dl.toggleExpanded {
                PointerEffects.fit(draftToggle, card: card.frame, radius: ChatMetrics.insetCardRadius)
            } else {
                draftToggle.layer.cornerRadius = 8
                PointerEffects.outlineDidLayout(draftToggle)
            }
        } else {
            toggleRowId = nil
            draftToggle.isHidden = true
        }
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
        // VoiceOver: folded rows speak through their toggle button; cards speak through the card + links + buttons.
        let links: [UIView] = (dl.threadFrame != nil ? [threadToggle] : []) + (dl.showAllFrame != nil ? [showAll] : [])
        if !hasCard, dl.toggleFrame != nil {
            contentView.accessibilityElements = [draftToggle]
        } else if dl.toggleFrame != nil {
            contentView.accessibilityElements = [draftToggle] + links
        } else {
            contentView.accessibilityElements = [card] + links + (dl.stacked ? ordered : ordered.reversed())
        }
    }

    private func makeDraftButton(_ kind: DraftButton) -> UIButton {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "draft.\(kind)"
        button.addAction(UIAction { [weak self] _ in
            guard let self, let draft = self.draft, draft.state == .waiting, !draft.editing else { return }
            self.handler?.draftCard(draft, tapped: kind)
        }, for: .primaryActionTriggered)
        contentView.addSubview(button)
        #if targetEnvironment(macCatalyst)
        PointerEffects.button(button)   // [Mac AAA 2026-11-16] as the approval's buttons
        #endif
        return button
    }

    private func draftConfig(_ kind: DraftButton, font: UIFont) -> UIButton.Configuration {
        var c: UIButton.Configuration
        switch kind {
        case .send:
            c = .filled()
            c.baseBackgroundColor = ChatPalette.tint
            c.baseForegroundColor = ChatPalette.onTint   // [paper-ink]
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
