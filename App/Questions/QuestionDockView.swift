import UIKit

// The question dock (spec 1x §4.3, MEM:phone-question-dock, MEM:question-dock-shadow-band): a bot's clarify questions
// in the composer's place, one page per question. The dock fits the page on show (owner 2026-10-30: sizing every page
// to the tallest left a short question with a band of empty card under its choices); Next and Back move to the new
// height in one animation that carries the transcript with it. [glass-phone] The card is a native Liquid Glass panel
// (`UIGlassEffect(.regular)`, the composer's family): the owner reversed Q12's "not glass" on 2026-10-30 ("more Liquid
// Glass"). The glass brings its own edge and shadow; what people read and pick keeps a solid fill. Measured over a busy
// transcript the question on bare glass fell to 2.7–3.3:1 (dark, a photo behind), so the text section (step, Skip All,
// the question, the choices) sits on an inner card 8 pt inside the glass, and Back is a solid capsule like Next.
// [qcard-frost] The inner card is frosted (`DockFill.frost`), not solid: solid it read as a white slab over a chat's
// picture (owner 2026-11-18).
// The Desktop Look has no glass: there the card stays today's solid elevated panel with its
// hairline and an upward-only shadow (the dock draws that itself, so ThemeChrome leaves it alone). The card's bottom
// sits 8 pt from the screen edge with corners that follow the screen while the keyboard is down, 4 pt above the keys
// while it is up.

// [question-tidy] Owner 2026-11-10 (design pick 2): one card, not three. The choices are plain rows on the card (the
// solid inner card on glass, the panel in the Desktop Look) under hairlines, with no box of their own; "Recommended" is
// a small tag at the row's trailing edge, so every choice is one height; "1 of 2" follows small progress bars; and a
// tap on a pick-one choice moves on to the next question, so the first page has no Next until it has an answer (the
// last page keeps Send, and a page reached with Back or one being typed in keeps Next).

@MainActor protocol QuestionDockDelegate: AnyObject {
    func dockSend(_ dock: QuestionDockView)
    func dockSkip(_ dock: QuestionDockView)
    func dockMinimize(_ dock: QuestionDockView)
    func dockExplain(_ dock: QuestionDockView)
    /// Page or picks changed (saved to the centre by request id).
    func dockDraftChanged(_ dock: QuestionDockView)
}

extension QuestionDockDelegate {
    func dockExplain(_ dock: QuestionDockView) {}
}

final class QuestionDockView: UIView, KeepsKeyboardOnTap {
    static let explainFirstAnswer = "Please explain the context and options in chat first before asking me to choose."
    let prompt: ClarifyPrompt
    private(set) var draft: ClarifyDraft
    weak var delegate: QuestionDockDelegate?
    /// Send or Skip is on its way: Skip, Back and every choice are disabled; Send reads "Sending…".
    var sending: Sending = .none {
        didSet {
            // [question-dictate] A take still recording into the card ends with it, nothing typed.
            if sending != .none { dictation?.cancel(why: sending == .send ? "the question card was sent" : "the question was skipped") }
            updateChrome()
        }
    }
    /// [question-dictate] The screen's dictation into the card (#438): every page's answer field gets the mic.
    weak var dictation: QuestionDictation? { didSet { pages.forEach { $0.dictation = dictation }; updateChrome() } }
    /// [question-dictate] A take types into one of this card's fields: Next and Send wait for its words (Done or ✕ on
    /// its row ends it), as the composer's Send gives way to Stop Dictation.
    var isDictating: Bool {
        guard let dictation, let field = dictation.activeField else { return false }
        return field.isDescendant(of: self)
    }
    enum Sending { case none, send, skip }

    /// Glass off the Desktop Look, the solid elevated panel in it (`applyLook`).
    private let card = UIVisualEffectView()
    /// [glass-phone] The solid card the text section sits on inside the glass (hidden in the Desktop Look).
    private let textCard = UIView()
    private let stepLabel = UILabel()
    /// [question-tidy] One small bar per question before "1 of 2", tinted up to the shown page.
    private let stepBars = StepBarsView()
    private let foot = UIView()
    /// [question-tidy] The foot (Back, Next) is away: the card ends under the text section.
    private var bareBottom: NSLayoutConstraint!
    private var autoAdvance: DispatchWorkItem?
    private let skipButton = UIButton(type: .system)
    private let minimizeButton = UIButton(type: .system)
    private let pagesScroll = PagesScrollView()
    private let pagesHost = UIView()
    private var pages: [QuestionPageView] = []
    /// The shown page's bottom is the pages' bottom: only that page sets the dock's height.
    private var pageFits: [NSLayoutConstraint] = []
    private let backButton = UIButton(type: .system)
    private let explainButton = UIButton(type: .system)
    private let primaryButton = UIButton(type: .system)
    private var bottomPadding: NSLayoutConstraint!
    private var keyboardDown: Bool?
    private let hairline = CAShapeLayer()

    /// [questions] A question that went unanswered, answered from its card: Skip reads Cancel (it only closes the dock)
    /// and Send puts the answers in the chat as a message.
    let later: Bool

    init(prompt: ClarifyPrompt, draft: ClarifyDraft, later: Bool = false) {
        self.prompt = prompt
        self.draft = draft
        self.later = later
        super.init(frame: .zero)
        build()
        showPage(draft.page, focus: false)
        updateChrome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var page: Int { draft.page }
    var isLastPage: Bool { draft.page >= prompt.questions.count - 1 }
    var answeredCount: Int {
        prompt.questions.filter { ClarifyStaging.stagedAnswer($0, draft.stages[$0.qid] ?? ClarifyStage()) != nil }.count
    }

    /// Locks a reconnect replayed (`answers` in `open_requests`) show as picked on the questions this draft has no
    /// stage for yet: the user's own picks always win (§4.3, web `QuestionPages`). True when anything was filled.
    @discardableResult func mergeReplayed(_ locked: [String: String?]) -> Bool {
        guard sending == .none, !locked.isEmpty else { return false }
        var filled = false
        for (index, question) in prompt.questions.enumerated() where draft.stages[question.qid] == nil {
            guard let stage = ClarifyStaging.replay(question, locked[question.qid]) else { continue }
            draft.stages[question.qid] = stage
            pages[index].showReplayed(stage)
            filled = true
        }
        if filled { updateChrome() }
        return filled
    }

    /// The answers Send locks, in question order (nil = no answer).
    var answers: [(qid: String, answer: String?)] {
        prompt.questions.map { ($0.qid, ClarifyStaging.stagedAnswer($0, draft.stages[$0.qid] ?? ClarifyStage())) }
    }

    /// Keep the draft and page, but stop a queued pick-one advance and release the keyboard while reading.
    func setMinimized(_ minimized: Bool) {
        draft.minimized = minimized
        if minimized {
            dictation?.cancel(why: "the question card was minimized")   // [question-dictate]
            autoAdvance?.cancel()
            autoAdvance = nil
            endEditing(true)
            resignFirstResponder()
        }
        delegate?.dockDraftChanged(self)
    }

    // MARK: Build

    private func build() {
        accessibilityIdentifier = "question.dock"
        // The look's shadow is cast upward only, from a path inset 10 pt: nothing spills below the card (shadow-band fix).
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: -8)

        DesktopLayout.keepOwnLook(card)      // the Desktop Look's solid panel is drawn here (applyLook), not flattened
        card.translatesAutoresizingMaskIntoConstraints = false
        card.clipsToBounds = true
        addSubview(card)
        textCard.backgroundColor = DockFill.panel
        textCard.cornerConfiguration = .uniformCorners(radius: .fixed(Self.textCardRadius))
        textCard.translatesAutoresizingMaskIntoConstraints = false
        textCard.isUserInteractionEnabled = false
        textCard.accessibilityIdentifier = "question.textCard"
        card.contentView.addSubview(textCard)
        hairline.fillColor = nil
        layer.addSublayer(hairline)
        card.isAccessibilityElement = false
        card.accessibilityContainerType = .semanticGroup
        card.accessibilityLabel = prompt.questions.count > 1 ? "Questions, \(draft.page + 1) of \(prompt.questions.count)" : "Question"

        stepLabel.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: HQFont.system(ofSize: 13, weight: .semibold))
        stepLabel.adjustsFontForContentSizeCategory = true
        stepLabel.textColor = ChatPalette.label2
        stepLabel.accessibilityIdentifier = "question.step"
        stepLabel.numberOfLines = 0
        stepLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var skip = UIButton.Configuration.plain()
        // Skip answers {} (spec 1x-questions.md: cancel-all), so on several questions it says it skips them all.
        skip.title = later ? "Cancel" : prompt.questions.count > 1 ? "Skip All" : "Skip"
        skip.baseForegroundColor = ChatPalette.tintText
        skip.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 0)
        skip.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a; a.font = HQFont.preferred(.body); return a
        }
        skipButton.configuration = skip
        skipButton.accessibilityIdentifier = "question.skip"
        if prompt.questions.count > 1 && !later { skipButton.accessibilityLabel = "Skip All Questions" }
        skipButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        skipButton.setContentHuggingPriority(.required, for: .horizontal)
        skipButton.addAction(UIAction { [weak self] _ in self.map { $0.delegate?.dockSkip($0) } }, for: .primaryActionTriggered)

        var minimize = UIButton.Configuration.plain()
        minimize.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(textStyle: .body, scale: .medium))
        minimize.baseForegroundColor = ChatPalette.tintText
        minimizeButton.configuration = minimize
        minimizeButton.accessibilityIdentifier = "question.minimize"
        minimizeButton.accessibilityLabel = "Minimize question"
        minimizeButton.accessibilityHint = "Keeps your answers so you can read the conversation."
        minimizeButton.addAction(UIAction { [weak self] _ in self.map { $0.delegate?.dockMinimize($0) } }, for: .primaryActionTriggered)

        let head = UIView()
        head.translatesAutoresizingMaskIntoConstraints = false
        stepLabel.translatesAutoresizingMaskIntoConstraints = false
        skipButton.translatesAutoresizingMaskIntoConstraints = false
        minimizeButton.translatesAutoresizingMaskIntoConstraints = false
        stepBars.translatesAutoresizingMaskIntoConstraints = false
        stepBars.count = prompt.questions.count
        stepBars.isHidden = !stepBars.shows
        head.addSubview(stepBars)
        head.addSubview(stepLabel)
        head.addSubview(skipButton)
        head.addSubview(minimizeButton)
        card.contentView.addSubview(head)

        pagesScroll.translatesAutoresizingMaskIntoConstraints = false
        pagesScroll.showsVerticalScrollIndicator = true
        pagesScroll.alwaysBounceVertical = false
        pagesScroll.keyboardDismissMode = .none
        pagesScroll.onResize = { [weak self] in self?.keepFieldInView() }
        pagesHost.translatesAutoresizingMaskIntoConstraints = false
        pagesScroll.addSubview(pagesHost)
        card.contentView.addSubview(pagesScroll)
        var pageConstraints: [NSLayoutConstraint] = []
        for (index, question) in prompt.questions.enumerated() {
            let page = QuestionPageView(question: question, stage: draft.stages[question.qid] ?? ClarifyStage(),
                                        last: index == prompt.questions.count - 1)
            page.translatesAutoresizingMaskIntoConstraints = false
            page.accessibilityIdentifier = "question.page.\(index)"
            page.onStage = { [weak self] stage in self?.stageChanged(question.qid, stage) }
            page.onReturn = { [weak self] in self?.returnPressed() }
            page.onFocus = { [weak self] in self?.keepFieldInView() }
            page.onPicked = { [weak self] in self?.pickedOne(on: index) }
            pagesHost.addSubview(page)
            pages.append(page)
            pageConstraints += [
                page.topAnchor.constraint(equalTo: pagesHost.topAnchor),
                page.leadingAnchor.constraint(equalTo: pagesHost.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: pagesHost.trailingAnchor),
            ]
            pageFits.append(pagesHost.bottomAnchor.constraint(equalTo: page.bottomAnchor))
        }

        backButton.accessibilityIdentifier = "question.back"
        backButton.addAction(UIAction { [weak self] _ in self?.go(by: -1) }, for: .primaryActionTriggered)
        explainButton.accessibilityIdentifier = "question.explain"
        explainButton.accessibilityLabel = "Explain first"
        explainButton.accessibilityHint = "Asks for the context in chat before choosing."
        explainButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        explainButton.addAction(UIAction { [weak self] _ in self.map { $0.delegate?.dockExplain($0) } }, for: .primaryActionTriggered)
        primaryButton.accessibilityIdentifier = "question.primary"
        primaryButton.addAction(UIAction { [weak self] _ in self?.primaryTapped() }, for: .primaryActionTriggered)
        foot.translatesAutoresizingMaskIntoConstraints = false
        backButton.translatesAutoresizingMaskIntoConstraints = false
        explainButton.translatesAutoresizingMaskIntoConstraints = false
        primaryButton.translatesAutoresizingMaskIntoConstraints = false
        foot.addSubview(backButton)
        foot.addSubview(explainButton)
        foot.addSubview(primaryButton)
        card.contentView.addSubview(foot)

        bottomPadding = foot.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12)
        bareBottom = pagesScroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -(Self.textCardInset + 8))
        let fill = pagesScroll.heightAnchor.constraint(equalTo: pagesHost.heightAnchor)
        fill.priority = .defaultHigh - 1
        NSLayoutConstraint.activate(pageConstraints + [
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            textCard.topAnchor.constraint(equalTo: card.topAnchor, constant: Self.textCardInset),
            textCard.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.textCardInset),
            textCard.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.textCardInset),
            textCard.bottomAnchor.constraint(equalTo: pagesScroll.bottomAnchor, constant: Self.textCardInset),
            head.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            head.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            head.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            head.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            stepBars.leadingAnchor.constraint(equalTo: head.leadingAnchor),
            stepBars.centerYAnchor.constraint(equalTo: head.centerYAnchor),
            stepLabel.leadingAnchor.constraint(equalTo: stepBars.shows ? stepBars.trailingAnchor : head.leadingAnchor,
                                               constant: stepBars.shows ? 8 : 0),
            stepLabel.centerYAnchor.constraint(equalTo: head.centerYAnchor),
            stepLabel.trailingAnchor.constraint(lessThanOrEqualTo: minimizeButton.leadingAnchor, constant: -8),
            stepLabel.topAnchor.constraint(greaterThanOrEqualTo: head.topAnchor, constant: 6),
            minimizeButton.trailingAnchor.constraint(equalTo: skipButton.leadingAnchor, constant: -4),
            minimizeButton.topAnchor.constraint(equalTo: head.topAnchor),
            minimizeButton.bottomAnchor.constraint(equalTo: head.bottomAnchor),
            minimizeButton.widthAnchor.constraint(equalToConstant: 44),
            skipButton.trailingAnchor.constraint(equalTo: head.trailingAnchor),
            skipButton.topAnchor.constraint(equalTo: head.topAnchor),
            skipButton.bottomAnchor.constraint(equalTo: head.bottomAnchor),
            skipButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            pagesScroll.topAnchor.constraint(equalTo: head.bottomAnchor),
            pagesScroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            pagesScroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            fill,
            pagesHost.topAnchor.constraint(equalTo: pagesScroll.contentLayoutGuide.topAnchor),
            pagesHost.bottomAnchor.constraint(equalTo: pagesScroll.contentLayoutGuide.bottomAnchor),
            pagesHost.leadingAnchor.constraint(equalTo: pagesScroll.contentLayoutGuide.leadingAnchor),
            pagesHost.trailingAnchor.constraint(equalTo: pagesScroll.contentLayoutGuide.trailingAnchor),
            pagesHost.widthAnchor.constraint(equalTo: pagesScroll.frameLayoutGuide.widthAnchor),
            foot.topAnchor.constraint(equalTo: pagesScroll.bottomAnchor, constant: 16),
            foot.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            foot.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            bottomPadding,
            backButton.leadingAnchor.constraint(equalTo: foot.leadingAnchor),
            backButton.centerYAnchor.constraint(equalTo: foot.centerYAnchor),
            backButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            explainButton.leadingAnchor.constraint(equalTo: foot.leadingAnchor),
            explainButton.centerYAnchor.constraint(equalTo: foot.centerYAnchor),
            explainButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            explainButton.trailingAnchor.constraint(lessThanOrEqualTo: primaryButton.leadingAnchor, constant: -8),
            primaryButton.trailingAnchor.constraint(equalTo: foot.trailingAnchor),
            primaryButton.topAnchor.constraint(equalTo: foot.topAnchor),
            primaryButton.bottomAnchor.constraint(equalTo: foot.bottomAnchor),
            primaryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            primaryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
            backButton.trailingAnchor.constraint(lessThanOrEqualTo: primaryButton.leadingAnchor, constant: -8),
        ])
        applyLook()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (dock: QuestionDockView, _) in
            dock.applyLook()
        }
        // [qcard-frost] Reduce Transparency / Increase Contrast turned on while the card shows make it solid at once.
        NotificationCenter.default.addObserver(self, selector: #selector(accessibilityChanged), name: HQAccessibility.didChange, object: nil)
        // [question-dictate] Next and Send wait while a take types into the card.
        NotificationCenter.default.addObserver(self, selector: #selector(dictationChanged), name: DictationController.didChange, object: nil)
    }

    @objc private func accessibilityChanged() { applyLook() }
    @objc private func dictationChanged() { updateChrome() }

    /// [question-dictate] The shown page's answer field for Dictate with Hermes ("Something else…" opened for it).
    func fieldForDictation() -> DockTextField? {
        guard sending == .none, !draft.minimized, pages.indices.contains(draft.page) else { return nil }
        return pages[draft.page].fieldForDictation()
    }

    /// Glass, or (Desktop Look) the solid elevated panel with its hairline and upward shadow. Runs again on every theme
    /// change, so turning the look on or off live switches the card.
    private func applyLook() {
        let desktop = Theme.isDesktop
        if desktop {
            if card.effect != nil { card.effect = nil }
            card.backgroundColor = ChatPalette.elevated   // the look's floating panel, in the skin's hue
        } else {
            // Untinted and not interactive: the card is a panel, its choices and buttons are the controls (as the
            // queue card's glass).
            if !(card.effect is UIGlassEffect) { card.effect = UIGlassEffect(style: .regular) }
            card.backgroundColor = nil
        }
        layer.shadowOpacity = desktop ? 0.16 : 0
        hairline.isHidden = !desktop
        textCard.isHidden = desktop
        textCard.backgroundColor = DockFill.textCard(traitCollection, solid: Self.wantsSolidTextCard)
        configureBack(desktop: desktop)
        configureExplain(desktop: desktop)
        updateChrome()
        updateHairline()
    }

    /// The text section's solid card: 8 pt inside the glass, its corners concentric with the card's 26 pt.
    static let textCardInset: CGFloat = 8
    static var textCardRadius: CGFloat { 26 - textCardInset }

    /// Back: the look's plain tinted words; on glass a solid capsule (the words would sit on bare glass).
    private func configureBack(desktop: Bool) {
        var back = desktop ? UIButton.Configuration.plain() : UIButton.Configuration.filled()
        back.title = "Back"
        back.image = UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(textStyle: .body, scale: .medium))
        back.imagePadding = 4
        back.baseForegroundColor = ChatPalette.tintText
        if desktop {
            back.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 12)
        } else {
            back.baseBackgroundColor = DockFill.answers
            back.cornerStyle = .capsule
            back.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 20)
        }
        back.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a; a.font = HQFont.preferred(.body); return a
        }
        backButton.configuration = back
    }

    /// Explain first: sits on the leading side of the foot on page 1 when Back is hidden, giving a one-tap way to ask
    /// the bot for the missing context in chat instead of getting stuck in Skip.
    private func configureExplain(desktop: Bool) {
        var explain = desktop ? UIButton.Configuration.plain() : UIButton.Configuration.filled()
        explain.title = "Explain first"
        explain.baseForegroundColor = ChatPalette.tintText
        if desktop {
            explain.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 12)
        } else {
            explain.baseBackgroundColor = DockFill.answers
            explain.cornerStyle = .capsule
            explain.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        }
        explain.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a
            a.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: HQFont.system(ofSize: 15, weight: .medium), maximumPointSize: 22)
            return a
        }
        explainButton.configuration = explain
        PointerEffects.surface(explainButton)
    }

    /// Stages a plain-language request for context on the first question so `dockSend` locks and records it cleanly.
    func stageExplainFirst() {
        guard let first = prompt.questions.first else { return }
        autoAdvance?.cancel()
        autoAdvance = nil
        let stage = ClarifyStage(choices: [], draft: Self.explainFirstAnswer, other: true)
        draft.stages = [first.qid: stage]
        draft.page = 0
        if pages.indices.contains(0) { pages[0].showReplayed(stage) }
        updateChrome()
    }

    var showsExplain: Bool {
        guard !later, draft.page == 0, !footHidden, let first = prompt.questions.first else { return false }
        guard !(first.choices ?? []).isEmpty, !VerificationCodePrompt.asksForCode(first.question) else { return false }
        return prompt.questions.count == 1 || answeredCount == 0
    }

    /// Whether the text section sits on its card now (tests).
    var hasTextCard: Bool { !textCard.isHidden }

    /// The text card's opacity now (tests): `DockFill.frost`, or 1 with Reduce Transparency or more contrast.
    var textCardAlpha: CGFloat { textCard.backgroundColor?.cgColor.alpha ?? 0 }

    /// [qcard-frost] Reduce Transparency and Increase Contrast keep the card fully solid.
    static var wantsSolidTextCard: Bool { HQAccessibility.reduceTransparency || HQAccessibility.increaseContrast }

    /// Whether the card is glass now (tests).
    var isGlass: Bool { card.effect is UIGlassEffect }

    // MARK: Paging

    /// A field of the shown page is being typed in.
    var isEditingText: Bool { pages.indices.contains(draft.page) && pages[draft.page].isEditing }

    /// The shown page's field takes the keyboard (a dock that replaced one being typed in keeps it up).
    func focusShownField() {
        guard pages.indices.contains(draft.page) else { return }
        pages[draft.page].focusField()
    }

    private func showPage(_ index: Int, focus: Bool) {
        let index = min(max(0, index), max(0, pages.count - 1))
        let typing = pages.contains { $0.isEditing }
        draft.page = index
        guard pages.indices.contains(index) else { updateChrome(); return }
        // The new page shows first and, when it is only a field, takes the focus before the old page hides: hiding the
        // view that holds the first responder resigns it, and the keyboard started down and came back up (verify round
        // 1: "Something else…" → Next dipped the keyboard and the dock). The focus moves field to field instead.
        let next = pages[index]
        next.isHidden = false
        next.accessibilityElementsHidden = false
        next.isUserInteractionEnabled = true
        if focus, typing, next.isFieldOnly { next.focusField() }
        for (i, page) in pages.enumerated() where i != index {
            page.isHidden = true
            page.accessibilityElementsHidden = true
            page.isUserInteractionEnabled = false
        }
        for (i, fit) in pageFits.enumerated() { fit.isActive = i == index }
        if focus, typing, !next.isFieldOnly { endEditing(true) }
        card.accessibilityLabel = prompt.questions.count > 1 ? "Questions, \(index + 1) of \(prompt.questions.count)" : "Question"
        pagesScroll.setContentOffset(.zero, animated: false)
        updateChrome()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.pagesScroll.flashScrollIndicators()
            #if targetEnvironment(macCatalyst)
            self?.takeKeys()
            #if DEBUG
            self?.debugPressKeys()
            #endif
            #endif
        }
    }

    #if DEBUG && targetEnvironment(macCatalyst)
    /// [mac-audit] `-HQDebugQuestionKeys "2,ret,esc"`: 1.5 s after the card shows, each key in turn (0.6 s apart) as its
    /// key command would run it (the system can't be made to type into the app from a script); `esc` is Escape's
    /// ladder step. Logs whether the card held the keyboard.
    private func debugPressKeys() {
        guard let list = UserDefaults.standard.string(forKey: "HQDebugQuestionKeys") else { return }
        print("[HQDebugQuestionKeys] card first responder: \(isFirstResponder)")
        for (i, key) in list.components(separatedBy: ",").enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + 0.6 * Double(i)) { [weak self] in
                guard let self else { return }
                if key == "esc" { self.escapePressed(); return }
                let input = key == "ret" ? "\r" : key
                let command = self.keyCommands?.first { $0.input == input }
                print("[HQDebugQuestionKeys] \(key): \(command == nil ? "no command" : "pressed")")
                if let command, let action = command.action { _ = self.perform(action, with: command) }
            }
        }
    }
    #endif

    #if targetEnvironment(macCatalyst)
    // MARK: [mac-audit] Keys

    // Owner 2026-11-02 (Mac audit #26): the card took no keys. On the Mac it holds the keyboard while it is up (the
    // composer it replaces has gone), so 1–9 pick the matching choice (the number after the last opens "Something
    // else…"), Return is Next or Send as the field's Return is, and Escape is Skip (`AppDelegate.hqEscape`). While
    // "Something else…" is being typed in, the keys are the field's.

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard sending == .none, !draft.minimized, pages.indices.contains(draft.page), !pages[draft.page].isEditing else { return [] }
        let page = pages[draft.page]
        var commands = (0..<page.numberedChoices).map { i -> UIKeyCommand in
            let command = UIKeyCommand(input: "\(i + 1)", modifierFlags: [], action: #selector(numberKey(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        commands.append(UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(returnKey)))
        return commands
    }

    @objc private func numberKey(_ command: UIKeyCommand) {
        guard sending == .none, let number = command.input.flatMap(Int.init), pages.indices.contains(draft.page) else { return }
        pages[draft.page].pick(number: number)
    }

    @objc private func returnKey() { returnPressed() }

    /// Something in the card is being typed in ("Something else…"), so Escape leaves that field first. The card itself
    /// holding the keys is not typing (Mac polish #7: View's Escape item reads Skip Question then).
    var isTyping: Bool { pages.contains { $0.isEditing } }

    /// The card takes the keyboard when nothing in it is being typed in (a pick, a page turn, its arrival).
    func takeKeys() {
        guard window != nil, !draft.minimized, !isFirstResponder, !isTyping else { return }
        becomeFirstResponder()
    }

    /// Escape: out of "Something else…" first (the words stay), else Skip, as its button does (asking first when
    /// answers would be lost).
    func escapePressed() {
        guard sending == .none, !draft.minimized else { return }
        if isDictating {   // [question-dictate] the dictation first, as its ✕
            dictation?.cancel(why: "cancelled")
        } else if isTyping {
            endEditing(true)
            takeKeys()
        } else {
            delegate?.dockSkip(self)
        }
    }
    #endif

    private func go(by delta: Int) {
        autoAdvance?.cancel()
        guard sending == .none else { return }
        let target = draft.page + delta
        guard target >= 0, target < pages.count else { return }
        dictation?.cancel(why: "the question card turned its page")   // [question-dictate] its field goes out of sight
        showPage(target, focus: true)
        resizeToPage()
        delegate?.dockDraftChanged(self)
        HQAnnounce.screenChanged(pages[draft.page])
        #if targetEnvironment(macCatalyst)
        takeKeys()
        #endif
    }

    /// The dock takes the new page's height in one move, and the chat's layout pass in the same animation carries the
    /// transcript's inset with it (a chat at its newest end stays there).
    private func resizeToPage() {
        guard let host = superview, window != nil else { return }
        setNeedsLayout()
        host.setNeedsLayout()
        guard !HQMotion.reduced else { host.layoutIfNeeded(); return }
        UIView.animate(withDuration: HQMotion.move, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) { host.layoutIfNeeded() }
    }

    private func primaryTapped() {
        guard !isDictating else { return }   // [question-dictate]
        if isLastPage {
            guard sending == .none, answeredCount > 0 else { return }
            delegate?.dockSend(self)
        } else {
            go(by: 1)
        }
    }

    /// Return in a field: Next on earlier pages, Send on the last when an answer exists.
    private func returnPressed() {
        guard !isDictating else { return }   // [question-dictate] the words aren't in the field yet
        if !isLastPage { go(by: 1) } else if sending == .none, answeredCount > 0 { delegate?.dockSend(self) }
    }

    private func stageChanged(_ qid: String, _ stage: ClarifyStage) {
        draft.stages[qid] = stage
        updateChrome()
        delegate?.dockDraftChanged(self)
        #if targetEnvironment(macCatalyst)
        takeKeys()
        #endif
    }

    private func updateChrome() {
        let count = prompt.questions.count
        // The bars say "question"; the words are the place. VoiceOver and the tests still hear "Question 2 of 3".
        stepLabel.text = count > 1 ? (stepBars.shows ? "\(draft.page + 1) of \(count)" : "Question \(draft.page + 1) of \(count)") : "Question"
        stepLabel.accessibilityLabel = count > 1 ? "Question \(draft.page + 1) of \(count)" : "Question"
        stepBars.current = draft.page
        updateFoot()
        backButton.isHidden = draft.page == 0
        backButton.isEnabled = sending == .none
        explainButton.isHidden = !showsExplain
        explainButton.isEnabled = sending == .none && !isDictating
        skipButton.isEnabled = sending == .none
        minimizeButton.isEnabled = sending == .none
        pages.forEach { $0.isLocked = sending != .none }
        var c = UIButton.Configuration.filled()
        c.baseBackgroundColor = ChatPalette.tint
        c.baseForegroundColor = ChatPalette.onTint   // [paper-ink]
        c.cornerStyle = .capsule
        c.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 22, bottom: 0, trailing: 22)
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a; a.font = HQFont.preferred(.headline); return a
        }
        let dictating = isDictating   // [question-dictate] its words aren't in the field yet
        if isLastPage {
            c.title = sending == .send ? "Sending…" : "Send"
            primaryButton.isEnabled = sending == .none && answeredCount > 0 && !dictating
        } else {
            c.title = "Next"
            primaryButton.isEnabled = sending == .none && !dictating
        }
        primaryButton.configuration = c
        // [glass-phone] On glass a disabled Send keeps an opaque fill (the system's disabled fill is see-through).
        primaryButton.configurationUpdateHandler = Theme.isDesktop ? nil : { button in
            guard var c = button.configuration else { return }
            c.background.backgroundColor = button.isEnabled ? ChatPalette.tint : DockFill.answers
            c.baseForegroundColor = button.isEnabled ? ChatPalette.onTint : ChatPalette.label3
            button.configuration = c
        }
        for (i, page) in pages.enumerated() { page.returnKey = i == count - 1 ? .send : .next }
    }

    // MARK: [question-tidy] Tap to move on

    /// A pick-one page that a tap answers and leaves: it has choices, takes one, and is not the last (the last page's
    /// tap never sends; Send does).
    private func advancesOnPick(_ index: Int) -> Bool {
        guard prompt.questions.indices.contains(index), index < prompt.questions.count - 1 else { return false }
        let question = prompt.questions[index]
        return !question.multiSelect && !(question.choices ?? []).isEmpty
    }

    /// The first page has no foot while a tap is all it needs: no Back to show, and Next would only skip the question.
    /// Once it has an answer (a pick, or words in "Something else…") or its field is open, Next is back, so a page
    /// returned to with Back can be left again without picking twice.
    var footHidden: Bool {
        guard draft.page == 0, advancesOnPick(0) else { return false }
        let question = prompt.questions[0]
        let stage = draft.stages[question.qid] ?? ClarifyStage()
        return !stage.other && ClarifyStaging.stagedAnswer(question, stage) == nil
    }

    private func updateFoot() {
        let hidden = footHidden
        guard foot.isHidden != hidden || bareBottom.isActive != hidden else { return }
        foot.isHidden = hidden
        // One of the two holds the card's bottom: the foot's, or the text section's own.
        if hidden { bottomPadding.isActive = false; bareBottom.isActive = true }
        else { bareBottom.isActive = false; bottomPadding.isActive = true }
        updateTextCardCorners()
        resizeToPage()
    }

    /// [question-corners] Owner 2026-11-10 (a phone screenshot of build 932): with no foot under it, the solid card's
    /// bottom reaches down into the glass card's screen-shaped bottom corners, and its own 18 pt corners were cut off
    /// by them at the bottom left and right. While the foot is away and the keyboard is down, its bottom corners
    /// follow the glass card's (concentric with them), as the glass card's follow the screen's.
    private func updateTextCardCorners() {
        let radius = UICornerRadius.fixed(Self.textCardRadius)
        if foot.isHidden, keyboardDown == true {
            textCard.cornerConfiguration = .corners(topLeftRadius: radius, topRightRadius: radius,
                                                    bottomLeftRadius: .containerConcentric(minimum: Self.textCardRadius),
                                                    bottomRightRadius: .containerConcentric(minimum: Self.textCardRadius))
        } else {
            textCard.cornerConfiguration = .uniformCorners(radius: radius)
        }
    }

    /// A choice on a pick-one page was tapped: the mark shows for a moment, then the next question.
    private func pickedOne(on index: Int) {
        autoAdvance?.cancel()
        guard advancesOnPick(index), index == draft.page, sending == .none else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.draft.page == index, !self.draft.minimized, self.sending == .none, self.window != nil else { return }
            self.go(by: 1)
        }
        autoAdvance = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.advanceDelay, execute: work)
    }

    /// Long enough to see the mark fill, short enough to feel like one tap.
    static let advanceDelay: TimeInterval = 0.22

    // MARK: Layout: sheet-style bottom while the keyboard is down

    override func layoutSubviews() {
        super.layoutSubviews()
        let down: Bool
        if let window {
            let bottom = convert(bounds, to: window).maxY
            down = window.bounds.maxY - bottom <= 10
        } else {
            down = true
        }
        if down != keyboardDown {
            keyboardDown = down
            let safe = window?.safeAreaInsets.bottom ?? 0
            bottomPadding.constant = -(down ? max(12, safe - 8) : 12)
            // Without the foot, the glass under the text section clears the home indicator the same way.
            bareBottom.constant = -(Self.textCardInset + (down ? max(8, safe - 12) : 8))
            if down {
                card.cornerConfiguration = .corners(topLeftRadius: .fixed(26), topRightRadius: .fixed(26),
                                                    bottomLeftRadius: .containerConcentric(minimum: 26),
                                                    bottomRightRadius: .containerConcentric(minimum: 26))
            } else {
                card.cornerConfiguration = .uniformCorners(radius: .fixed(26))
            }
            updateTextCardCorners()
            setNeedsLayout()
        }
        let path = bounds.insetBy(dx: 10, dy: 10)
        layer.shadowPath = UIBezierPath(roundedRect: path, cornerRadius: 26).cgPath
        updateHairline()
    }

    /// The edge line follows the card's whole outline, its bottom corners too (verify round 1: it stopped where the
    /// screen-concentric corners begin, so the outline looked broken).
    private func updateHairline() {
        hairline.lineWidth = HQShape.pixel(traitCollection.displayScale)
        hairline.strokeColor = ChatPalette.separator.resolvedColor(with: traitCollection).cgColor
        let r = bounds
        let half = min(r.width, r.height) / 2
        let tl = min(half, card.effectiveRadius(corner: .topLeft)), tr = min(half, card.effectiveRadius(corner: .topRight))
        let bl = min(half, card.effectiveRadius(corner: .bottomLeft)), br = min(half, card.effectiveRadius(corner: .bottomRight))
        let p = UIBezierPath()
        p.move(to: CGPoint(x: 0, y: tl))
        p.addArc(withCenter: CGPoint(x: tl, y: tl), radius: tl, startAngle: .pi, endAngle: 1.5 * .pi, clockwise: true)
        p.addLine(to: CGPoint(x: r.maxX - tr, y: 0))
        p.addArc(withCenter: CGPoint(x: r.maxX - tr, y: tr), radius: tr, startAngle: 1.5 * .pi, endAngle: 0, clockwise: true)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        p.addArc(withCenter: CGPoint(x: r.maxX - br, y: r.maxY - br), radius: br, startAngle: 0, endAngle: 0.5 * .pi, clockwise: true)
        p.addLine(to: CGPoint(x: bl, y: r.maxY))
        p.addArc(withCenter: CGPoint(x: bl, y: r.maxY - bl), radius: bl, startAngle: 0.5 * .pi, endAngle: .pi, clockwise: true)
        p.close()
        hairline.frame = bounds
        hairline.path = p.cgPath
    }

    /// The field being typed in stays in view as the keyboard rises, the dock shrinks or the field grows (owner
    /// 2026-11-01: tapping "Something else…" under a long question left the field out of sight).
    private func keepFieldInView() {
        guard pages.indices.contains(draft.page), let field = pages[draft.page].editingField else { return }
        pagesHost.layoutIfNeeded()   // the field's frame before the page's own layout pass is stale
        let rect = field.convert(field.bounds, to: pagesScroll).insetBy(dx: 0, dy: -8)
        pagesScroll.scrollRectToVisible(rect, animated: false)
    }

    /// The shown page's height (tests read this).
    var pagesHeight: CGFloat { pagesHost.bounds.height }
}

/// The pages' scroll view, telling the dock when its height or its page's height changes. While more of the page sits
/// below, its bottom edge fades out (owner 2026-11-01: a cut-off "Something else…" read as broken, not as more to scroll).
private final class PagesScrollView: UIScrollView {
    var onResize: (() -> Void)?
    private var seen: (CGFloat, CGFloat) = (0, 0)
    private let fade = CAGradientLayer()
    static let fadeHeight: CGFloat = 28

    /// Every scroll moves the bounds; the mask is in bounds space, so it moves with them (a layout pass doesn't follow
    /// every offset change, and a stale mask hid the whole page).
    override var bounds: CGRect { didSet { updateFade() } }
    override var contentSize: CGSize { didSet { updateFade() } }

    override func layoutSubviews() {
        super.layoutSubviews()
        let now = (bounds.height, contentSize.height)
        guard now != seen else { return }
        seen = now
        onResize?()
    }

    private func updateFade() {
        let more = contentOffset.y + bounds.height < contentSize.height - 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if more {
            let stop = max(0, 1 - Self.fadeHeight / max(1, bounds.height))
            fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
            fade.locations = [0, NSNumber(value: Double(stop)), 1]
            fade.frame = bounds
            if layer.mask !== fade { layer.mask = fade }
        } else if layer.mask != nil {
            layer.mask = nil
        }
        CATransaction.commit()
    }
}

// MARK: - One page

final class QuestionPageView: UIView, UITextViewDelegate, UITextFieldDelegate {
    /// The question to its choices or field (owner 2026-10-30: at 8 pt the grey list crowded the question).
    /// [question-tidy] 10: the choices are rows on the card now, the first under its own hairline.
    static let answersGap: CGFloat = 10
    /// [question-tidy] A pick-one choice was tapped (the dock moves on).
    var onPicked: (() -> Void)?
    let question: ClarifyQuestion
    private(set) var stage: ClarifyStage
    let last: Bool
    var onStage: ((ClarifyStage) -> Void)?
    var onReturn: (() -> Void)?
    var onFocus: (() -> Void)?
    var returnKey: UIReturnKeyType = .next { didSet { field?.returnKeyType = returnKey } }
    var isLocked = false {
        didSet {
            rows.forEach { $0.isEnabled = !isLocked }
            field?.isEditable = !isLocked
            field?.updateMic()   // [question-dictate] no dictating into a card on its way
        }
    }
    /// [question-dictate] The screen's dictation into the card: its answer field gets the mic (#438).
    weak var dictation: QuestionDictation? { didSet { if let field { dictation?.adopt(field) } } }

    private let stack = UIStackView()
    private var rows: [ChoiceRow] = []
    private var otherRow: ChoiceRow?
    private var field: DockTextField?
    private let list = UIView()
    private let listStack = UIStackView()

    var isFieldOnly: Bool { (question.choices ?? []).isEmpty }
    var isEditing: Bool { field?.isEditing == true }
    private var asksCode: Bool { VerificationCodePrompt.asksForCode(question.question) }

    init(question: ClarifyQuestion, stage: ClarifyStage, last: Bool) {
        self.question = question
        self.stage = stage
        self.last = last
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let title = UILabel()
        title.font = HQFont.preferred(.headline)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = ChatPalette.label
        title.numberOfLines = 0
        title.lineBreakMode = .byWordWrapping   // a word longer than the line still breaks
        title.text = question.question
        title.accessibilityTraits = .header
        stack.addArrangedSubview(title)
        if question.multiSelect {
            let hint = UILabel()
            hint.font = HQFont.preferred(.footnote)
            hint.adjustsFontForContentSizeCategory = true
            hint.textColor = ChatPalette.label2
            hint.text = "Choose any that apply."
            stack.setCustomSpacing(4, after: title)
            stack.addArrangedSubview(hint)
            stack.setCustomSpacing(Self.answersGap, after: hint)
        } else {
            stack.setCustomSpacing(Self.answersGap, after: title)
        }
        guard let choices = question.choices, !choices.isEmpty else {
            let f = DockTextField(placeholder: asksCode ? "Verification code" : "Type your answer…",
                                  accessibility: question.question, oneTimeCode: asksCode)
            f.text = stage.draft
            configure(f)
            stack.addArrangedSubview(f)
            field = f
            return
        }
        // [question-tidy] No fill or corners of its own: the rows lie on the card (solid on glass, the panel in the
        // Desktop Look), so the transcript still never reads through the choices.
        list.backgroundColor = .clear
        // The list is as tall as its rows: the page scrolls as one inside the dock (owner 2026-11-01: a list capped at
        // half the screen scrolled on its own under a long question, and "Something else…" sat cut off at its bottom).
        listStack.axis = .vertical
        listStack.translatesAutoresizingMaskIntoConstraints = false
        list.addSubview(listStack)
        NSLayoutConstraint.activate([
            listStack.topAnchor.constraint(equalTo: list.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: list.bottomAnchor),
            listStack.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: list.trailingAnchor),
        ])
        for (index, choice) in choices.enumerated() {
            let row = ChoiceRow(choice: choice, multi: question.multiSelect)
            row.accessibilityIdentifier = "question.choice.\(index)"
            row.addAction(UIAction { [weak self] _ in self?.choiceTapped(choice) }, for: .touchUpInside)
            rows.append(row)
            listStack.addArrangedSubview(Separator())   // the first row's too: it rules the choices off from the question
            listStack.addArrangedSubview(row)
        }
        listStack.addArrangedSubview(Separator())
        let other = ChoiceRow(choice: nil, multi: question.multiSelect)
        other.accessibilityIdentifier = "question.other"
        other.addAction(UIAction { [weak self] _ in self?.openOther() }, for: .touchUpInside)
        otherRow = other
        rows.append(other)
        listStack.addArrangedSubview(other)
        stack.addArrangedSubview(list)
        if stage.other { showOtherField(focus: false) }
        refreshMarks()
    }

    private func configure(_ f: DockTextField) {
        let identifier = isFieldOnly ? "question.field" : "question.otherField"
        f.returnKeyType = returnKey
        f.textView.delegate = self
        f.textView.autocapitalizationType = .sentences
        f.textView.accessibilityIdentifier = identifier
        if let codeField = f.codeField {
            codeField.delegate = self
            codeField.accessibilityIdentifier = identifier
            codeField.addTarget(self, action: #selector(codeFieldChanged(_:)), for: .editingChanged)
        }
        dictation?.adopt(f)   // [question-dictate]
    }

    private func choiceTapped(_ choice: String) {
        guard !isLocked else { return }
        Haptics.play(.selection)
        let wasOther = stage.other
        stage = ClarifyStaging.toggle(question, stage, choice)
        if wasOther && !stage.other { hideOtherField() }
        refreshMarks()
        onStage?(stage)
        if !question.multiSelect { onPicked?() }
    }

    private func openOther() {
        guard !isLocked, field == nil else { return }
        Haptics.play(.selection)
        stage = ClarifyStaging.openOther(question, stage)
        showOtherField(focus: true)
        refreshMarks()
        onStage?(stage)
    }

    /// "Something else…" becomes an inline field, focused in the same frame (the keyboard rises once).
    private func showOtherField(focus: Bool) {
        guard let other = otherRow, field == nil else { return }
        let f = DockTextField(placeholder: asksCode ? "Verification code" : "Type an answer or ask a question…",
                              accessibility: "Something else", inline: true, multi: question.multiSelect,
                              oneTimeCode: asksCode)
        f.text = stage.draft
        configure(f)
        field = f
        other.embed(f)
        if focus { f.focus() }
    }

    private func hideOtherField() {
        guard let f = field else { return }
        f.resign()
        otherRow?.embed(nil)
        field = nil
    }

    func focusField() { field?.focus() }

    /// [question-dictate] The page's answer field, "Something else…" opened for it when the page has choices (Dictate
    /// with Hermes, or a failure card's Try Again, while the card covers the composer). nil while locked.
    func fieldForDictation() -> DockTextField? {
        guard !isLocked else { return nil }
        if field == nil, !isFieldOnly {
            stage = ClarifyStaging.openOther(question, stage)
            showOtherField(focus: false)
            refreshMarks()
            onStage?(stage)
        }
        return field
    }

    /// The page's answer field, if it shows one (tests).
    var answerField: DockTextField? { field }

    #if targetEnvironment(macCatalyst)
    /// [mac-audit] How many number keys pick here: one per choice, then "Something else…" (nine at most).
    var numberedChoices: Int { isFieldOnly ? 0 : min(9, (question.choices?.count ?? 0) + 1) }

    /// [mac-audit] The number key `number` (1 is the first choice): as clicking that row does.
    func pick(number: Int) {
        guard let choices = question.choices, number >= 1, number <= numberedChoices else { return }
        if number <= choices.count { choiceTapped(choices[number - 1]) } else { openOther() }
    }
    #endif

    /// The field being typed in, for the dock to keep in view.
    var editingField: UIView? { isEditing ? field : nil }

    /// A replayed lock on a question the user hasn't touched (QuestionDockView.mergeReplayed).
    func showReplayed(_ stage: ClarifyStage) {
        self.stage = stage
        if isFieldOnly {
            field?.text = stage.draft
        } else if stage.other {
            showOtherField(focus: false)
            field?.text = stage.draft
        } else {
            hideOtherField()
        }
        refreshMarks()
    }

    private func refreshMarks() {
        for row in rows {
            if let choice = row.choice { row.picked = stage.choices.contains(choice) }
            else { row.picked = stage.other && !stage.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    // MARK: UITextViewDelegate

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text == "\n" {
            onReturn?()
            return false
        }
        return true
    }

    func textViewDidBeginEditing(_ textView: UITextView) { onFocus?() }

    func textViewDidChange(_ textView: UITextView) {
        stage.draft = textView.text
        field?.textChanged()
        refreshMarks()
        onStage?(stage)
    }

    // MARK: UITextFieldDelegate (verification-code questions)

    func textFieldDidBeginEditing(_ textField: UITextField) { onFocus?() }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onReturn?()
        return false
    }

    @objc private func codeFieldChanged(_ textField: UITextField) {
        stage.draft = textField.text ?? ""
        field?.textChanged()
        refreshMarks()
        onStage?(stage)
    }
}

/// One choice (or "Something else…"): ≥ 44 pt, 10 pt above and below, a 24 pt mark (circle single / rounded square
/// multi) at the card's text margin. [question-tidy] "Recommended" is a small tinted tag at the trailing edge, on the
/// first line, so a recommended choice is no taller than the others.
final class ChoiceRow: UIControl {
    let choice: String?
    let multi: Bool
    private let mark = MarkView()
    private let label = UILabel()
    private let recommendedTag = RecommendedTag()
    private let textStack = UIStackView()
    private var embedded: UIView?
    var picked = false { didSet { mark.on = picked; updateTraits() } }

    init(choice: String?, multi: Bool) {
        self.choice = choice
        self.multi = multi
        super.init(frame: .zero)
        mark.multi = multi
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.isUserInteractionEnabled = false
        addSubview(mark)
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.isUserInteractionEnabled = false
        textStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textStack)
        label.font = HQFont.preferred(.body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        if let choice {
            label.text = ClarifyText.bareChoice(choice)
            label.textColor = ChatPalette.label
        } else {
            label.text = "Something else…"
            label.textColor = ChatPalette.label2
        }
        textStack.addArrangedSubview(label)
        let recommended = choice.map(ClarifyText.isRecommended) ?? false
        layer.cornerRadius = 10          // the pressed fill is a soft block, not a bar across the card
        layer.cornerCurve = .continuous
        PointerEffects.surface(self)     // [mac] Feel list B: the same block under the pointer; its press is that fill, deeper
        var trailing = textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2)
        if recommended {
            recommendedTag.translatesAutoresizingMaskIntoConstraints = false
            recommendedTag.isUserInteractionEnabled = false
            addSubview(recommendedTag)
            // At most: the words keep their own width and the tag stays at the edge (an equal width stretched the tag).
            trailing = textStack.trailingAnchor.constraint(lessThanOrEqualTo: recommendedTag.leadingAnchor, constant: -8)
            NSLayoutConstraint.activate([
                recommendedTag.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                recommendedTag.centerYAnchor.constraint(equalTo: mark.centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            mark.widthAnchor.constraint(equalToConstant: 24),
            mark.heightAnchor.constraint(equalToConstant: 24),
            mark.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
            mark.centerYAnchor.constraint(equalTo: textStack.topAnchor, constant: max(12, label.font.lineHeight / 2)).withPriority(.defaultHigh),
            textStack.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 12),
            trailing,
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        isAccessibilityElement = true
        accessibilityLabel = choice.map(ClarifyText.bareChoice) ?? "Something else"
        if let choice, ClarifyText.isRecommended(choice) { accessibilityValue = "Recommended" }
        if multi && choice != nil { accessibilityHint = "Choose any that apply." }
        updateTraits()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func updateTraits() {
        accessibilityTraits = picked ? [.button, .selected] : .button
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted && !DeviceWord.isMac ? ChatPalette.fill3 : .clear }
    }

    override func accessibilityActivate() -> Bool {
        sendActions(for: .touchUpInside)
        return true
    }

    /// The inline "Something else" field takes the label's place (nil restores the label).
    func embed(_ view: UIView?) {
        embedded?.removeFromSuperview()
        embedded = view
        label.isHidden = view != nil
        isAccessibilityElement = view == nil
        if let view {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 8),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            ])
        }
    }
}

/// [question-tidy] "Recommended": Caption 1 semibold in the tint's text colour on a quiet tinted capsule. The row's
/// VoiceOver value says it, so the tag itself is not an element.
final class RecommendedTag: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: HQFont.system(ofSize: HQFont.legibleLiteral(12), weight: .semibold))
        label.adjustsFontForContentSizeCategory = true
        label.text = "Recommended"
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        layer.cornerRadius = 7
        layer.cornerCurve = .continuous
        isAccessibilityElement = false
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        update()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: RecommendedTag, _) in view.update() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func update() {
        label.textColor = ChatPalette.tintText
        backgroundColor = ChatPalette.tint.withAlphaComponent(0.16)
    }
}

/// [question-tidy] The questions as small bars before "1 of 2" (two to six of them; more would crowd Skip All, and
/// the words alone say it then). The bars up to the shown page are tinted.
final class StepBarsView: UIView {
    var count = 0 { didSet { invalidateIntrinsicContentSize(); setNeedsLayout() } }
    var current = 0 { didSet { if current != oldValue { setNeedsLayout() } } }
    var shows: Bool { (2...6).contains(count) }
    private var bars: [UIView] = []
    private static let bar = CGSize(width: 16, height: 4)
    private static let gap: CGFloat = 4

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        isUserInteractionEnabled = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: StepBarsView, _) in view.setNeedsLayout() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize {
        guard shows else { return .zero }
        return CGSize(width: CGFloat(count) * Self.bar.width + CGFloat(count - 1) * Self.gap, height: Self.bar.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let wanted = shows ? count : 0
        while bars.count < wanted { let bar = UIView(); bar.layer.cornerRadius = Self.bar.height / 2; addSubview(bar); bars.append(bar) }
        while bars.count > wanted { bars.removeLast().removeFromSuperview() }
        for (i, bar) in bars.enumerated() {
            bar.frame = CGRect(x: CGFloat(i) * (Self.bar.width + Self.gap), y: (bounds.height - Self.bar.height) / 2,
                               width: Self.bar.width, height: Self.bar.height)
            bar.backgroundColor = i <= current ? ChatPalette.tint : ChatPalette.label3.withAlphaComponent(0.5)
        }
    }
}

final class MarkView: UIView {
    var multi = false { didSet { setNeedsLayout() } }
    var on = false { didSet { update() } }
    private let check = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        check.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .heavy))
        check.tintColor = ChatPalette.onTint   // [paper-ink] on the tint when on
        check.contentMode = .center
        addSubview(check)
        layer.borderWidth = 1.5
        update()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: MarkView, _) in view.update() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = multi ? 7 : bounds.width / 2
        layer.cornerCurve = .continuous
        check.frame = bounds
    }

    private func update() {
        backgroundColor = on ? ChatPalette.tint : .clear
        layer.borderColor = (on ? ChatPalette.tint : ChatPalette.label3).resolvedColor(with: traitCollection).cgColor
        check.isHidden = !on
    }
}

final class Separator: UIView {
    private var hair: NSLayoutConstraint!

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = HQShape.pixel(traitCollection.displayScale)
        if hair.constant != h { hair.constant = h }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let line = UIView()
        line.backgroundColor = ChatPalette.separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        hair = heightAnchor.constraint(equalToConstant: 1.0 / 3)
        NSLayoutConstraint.activate([
            hair,
            line.leadingAnchor.constraint(equalTo: leadingAnchor),   // [question-tidy] the card's width: the rows have no box
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// A field that grows with its text from 44 to 132 pt, then scrolls (Fill 4, radius 12, padding 11/14).
/// [question-dictate] With voice in the chat, a mic at its trailing edge dictates into it (#438, `QuestionDictation`).
final class DockTextField: UIView {
    let textView = UITextView()
    /// When the question asks for a verification / one-time code, a real `UITextField` with `.oneTimeCode` stands in
    /// for `textView` so iOS and macOS reliably offer "From Messages" / "From Mail" AutoFill above the keyboard.
    let codeField: UITextField?
    let oneTimeCode: Bool
    private let placeholder = UILabel()
    private var height: NSLayoutConstraint!
    private var placeholderTrailing: NSLayoutConstraint!
    private var codeTrailing: NSLayoutConstraint?
    private let inline: Bool
    /// The text's own insets, before the mic's room.
    private let baseInset: UIEdgeInsets
    private let micButton = UIButton(type: .system)

    init(placeholder text: String, accessibility: String, inline: Bool = false, multi: Bool = false, oneTimeCode: Bool = false) {
        self.inline = inline
        self.oneTimeCode = oneTimeCode
        baseInset = inline ? UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4) : UIEdgeInsets(top: 11, left: 14, bottom: 11, right: 14)
        let otpField: UITextField? = oneTimeCode ? UITextField() : nil
        self.codeField = otpField
        super.init(frame: .zero)
        backgroundColor = inline ? .clear : DockFill.answers   // [glass-phone] opaque on the glass card
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        textView.backgroundColor = .clear
        textView.font = HQFont.preferred(.body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = ChatPalette.label
        textView.textContainerInset = baseInset
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.accessibilityLabel = accessibility
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isHidden = oneTimeCode
        addSubview(textView)
        placeholder.text = text
        placeholder.font = HQFont.preferred(.body)
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = ChatPalette.label3
        placeholder.isAccessibilityElement = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.isHidden = oneTimeCode
        addSubview(placeholder)
        if let otpField {
            otpField.backgroundColor = .clear
            otpField.font = HQFont.preferred(.body)
            otpField.adjustsFontForContentSizeCategory = true
            otpField.textColor = ChatPalette.label
            otpField.tintColor = ChatPalette.caret
            otpField.textContentType = .oneTimeCode
            otpField.autocorrectionType = .default      // keep QuickType AutoFill bar enabled for Messages / Mail codes
            otpField.autocapitalizationType = .none
            otpField.smartQuotesType = .no
            otpField.smartDashesType = .no
            otpField.spellCheckingType = .no
            otpField.keyboardType = .asciiCapable
            otpField.attributedPlaceholder = NSAttributedString(string: text, attributes: [.foregroundColor: ChatPalette.label3])
            otpField.accessibilityLabel = accessibility
            otpField.translatesAutoresizingMaskIntoConstraints = false
            addSubview(otpField)
        }
        height = heightAnchor.constraint(equalToConstant: 44)
        placeholderTrailing = placeholder.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        // [question-dictate] The composer's Dictate glyph, at the field's last line (as the composer's mic sits).
        var mic = UIButton.Configuration.plain()
        mic.image = UIImage(systemName: "mic", withConfiguration: UIImage.SymbolConfiguration(textStyle: .body, scale: .medium))
        mic.baseForegroundColor = ChatPalette.tintText
        micButton.configuration = mic
        micButton.accessibilityIdentifier = "question.dictate"
        micButton.accessibilityLabel = "Dictate"
        micButton.accessibilityHint = "Say your answer. The words go in this field."
        micButton.isHidden = true
        micButton.translatesAutoresizingMaskIntoConstraints = false
        micButton.addAction(UIAction { [weak self] _ in self?.onDictate?() }, for: .primaryActionTriggered)
        PointerEffects.surface(micButton)
        addSubview(micButton)
        var constraints: [NSLayoutConstraint] = [
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: textView.textContainerInset.left),
            placeholder.topAnchor.constraint(equalTo: topAnchor, constant: textView.textContainerInset.top),
            placeholderTrailing,
            micButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            micButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            micButton.widthAnchor.constraint(equalToConstant: Self.micSize),
            micButton.heightAnchor.constraint(equalToConstant: Self.micSize),
            height,
        ]
        if let otpField {
            let trailing = otpField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -baseInset.right)
            codeTrailing = trailing
            constraints.append(contentsOf: [
                otpField.topAnchor.constraint(equalTo: topAnchor),
                otpField.bottomAnchor.constraint(equalTo: bottomAnchor),
                otpField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: baseInset.left),
                trailing,
            ])
        }
        NSLayoutConstraint.activate(constraints)
    }

    // MARK: [question-dictate] Dictation (#438)

    static let micSize: CGFloat = 44

    /// The mic: the composer's dictation, its words typed here. nil: no mic (no voice in this chat).
    var onDictate: (() -> Void)? { didSet { updateMic() } }
    /// Off while another dictation records (one runs app-wide).
    var dictateEnabled = true { didSet { if dictateEnabled != oldValue { updateMic() } } }
    /// The field left the screen (a choice closed "Something else…", the card went): its take ends.
    var onLeftWindow: (() -> Void)?
    /// The mic shows (tests).
    var showsMic: Bool { !micButton.isHidden }
    var micEnabled: Bool { micButton.isEnabled }

    /// While a take types into this field its row, and the words heard above it, take the field's place, as the
    /// composer's dictation row takes its field's: the text view goes invisible but keeps the keyboard, and the words go
    /// in at its caret when they come back.
    var dictationContent: QuestionDictationView? {
        didSet {
            guard dictationContent !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let dictationContent {
                dictationContent.frame = bounds
                addSubview(dictationContent)
            }
            let showText = dictationContent == nil
            textView.alpha = showText ? 1 : 0
            placeholder.alpha = showText ? 1 : 0
            textView.accessibilityElementsHidden = !showText
            codeField?.alpha = showText ? 1 : 0
            codeField?.accessibilityElementsHidden = !showText
            updateMic()
            textChanged()
            setNeedsLayout()
        }
    }

    var returnKeyType: UIReturnKeyType {
        get { codeField?.returnKeyType ?? textView.returnKeyType }
        set {
            textView.returnKeyType = newValue
            codeField?.returnKeyType = newValue
        }
    }

    var isEditable: Bool {
        get { codeField?.isEnabled ?? textView.isEditable }
        set {
            textView.isEditable = newValue
            codeField?.isEnabled = newValue
        }
    }

    var isEditing: Bool { codeField?.isFirstResponder == true || textView.isFirstResponder }

    func focus() {
        if let codeField { codeField.becomeFirstResponder() } else { textView.becomeFirstResponder() }
    }

    func resign() {
        if let codeField, codeField.isFirstResponder { codeField.resignFirstResponder() }
        if textView.isFirstResponder { textView.resignFirstResponder() }
    }

    /// Dictated words go in at the caret as the composer's do (a space before them when the text there does not end in
    /// white space), the keyboard comes up, and the page takes them as typed words.
    func insertDictation(_ words: String) {
        guard isEditable else { return }
        if let codeField {
            let current = codeField.text ?? ""
            let result = ComposerView.dictationInsert(into: current, selection: NSRange(location: (current as NSString).length, length: 0), words: words)
            codeField.text = result.text
            codeField.becomeFirstResponder()
            codeField.sendActions(for: .editingChanged)
            textChanged()
            return
        }
        let result = ComposerView.dictationInsert(into: textView.text ?? "", selection: textView.selectedRange, words: words)
        textView.text = result.text
        textView.becomeFirstResponder()
        textView.selectedRange = NSRange(location: result.caret, length: 0)
        textView.delegate?.textViewDidChange?(textView)
        textChanged()
    }

    /// In a window, and neither it nor anything above it hidden (its page is the one on show).
    var isShowing: Bool {
        guard window != nil else { return false }
        var view: UIView? = self
        while let each = view {
            if each.isHidden { return false }
            view = each.superview
        }
        return true
    }

    /// Called when the page locks or unlocks the field too (Send or Skip on its way).
    func updateMic() {
        let shows = onDictate != nil && dictationContent == nil
        micButton.isHidden = !shows
        micButton.isEnabled = dictateEnabled && isEditable
        var inset = baseInset
        if onDictate != nil { inset.right = max(inset.right, Self.micSize - 4) }
        codeTrailing?.constant = -inset.right
        if textView.textContainerInset != inset {
            textView.textContainerInset = inset
            placeholderTrailing.constant = -(onDictate != nil ? Self.micSize : 8)
            textChanged()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { onLeftWindow?() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var text: String {
        get { codeField?.text ?? textView.text }
        set {
            textView.text = newValue
            codeField?.text = newValue
            textChanged()
        }
    }

    func textChanged() {
        let width = bounds.width > 0 ? bounds.width : 300
        if codeField != nil {
            placeholder.isHidden = true
            let target = dictationContent.map { max(44, ceil($0.height(for: width))) } ?? 44
            if abs(height.constant - target) > 0.5 { height.constant = target }
            return
        }
        placeholder.isHidden = !textView.text.isEmpty
        let fit = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        // [question-dictate] While dictating: the row, and the words heard above it.
        let target = dictationContent.map { max(44, ceil($0.height(for: width))) } ?? min(132, max(44, ceil(fit)))
        textView.isScrollEnabled = fit > 132
        if abs(height.constant - target) > 0.5 { height.constant = target }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textChanged()
        if let dictationContent, dictationContent.frame != bounds { dictationContent.frame = bounds }
    }
}

/// [glass-phone] The choice list's and the field's fill: Fill 4 laid over the elevated panel as one opaque colour. On
/// the solid card (the Desktop Look) it reads exactly as Fill 4 did; on the glass card nothing behind shows through
/// the words people pick from.
nonisolated enum DockFill {
    /// iOS's raised card, or a skin's card in its page's hue (a neutral grey panel looked off on a navy skin, owner
    /// 2026-11-01). The Desktop Look lays the choices on its own panel (`elevated`), so they read as the panel's hue,
    /// not the editor's greyer card.
    private static let card = ThemedColor.makeGroupedCard()
    private static let base = UIColor { traits in
        let desktop = ThemeTable.withSet(generation: traits[ThemeGenerationTrait.self]) { $0.state.desktopLook }
        return (desktop ? ChatPalette.elevated : card).resolvedColor(with: traits)
    }
    static let answers = UIColor { traits in
        over(base.resolvedColor(with: traits), ChatPalette.fill4.resolvedColor(with: traits))
    }
    /// The elevated panel as one opaque colour, for the text section's card inside the glass: a system background
    /// colour inside a glass effect's content view drew see-through (verified on the iOS 27 simulator).
    static let panel = UIColor { traits in
        over(base.resolvedColor(with: traits), .clear)
    }

    /// [qcard-frost] Owner 2026-11-18 (pick C, "the question card is too solid white"): the text card lets 40 % of
    /// the glass through, so the card takes the chat's picture instead of a flat white (Light) or black (Dark) slab.
    /// Measured on the iOS 27 simulator over a photo and a gradient in six skins, both appearances: the question stays
    /// at 9.4:1 or more (the solid card measured 10.8–13.3:1; bare glass 2.7–3.3:1).
    static let frost: CGFloat = 0.6

    /// The text card's fill, resolved now: the opaque panel at `frost`, or fully opaque when `solid`.
    static func textCard(_ traits: UITraitCollection, solid: Bool) -> UIColor {
        panel.resolvedColor(with: traits).withAlphaComponent(solid ? 1 : frost)
    }

    static func over(_ bottom: UIColor, _ top: UIColor) -> UIColor {
        var (br, bg, bb, ba): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (tr, tg, tb, ta): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        bottom.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        top.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        func mix(_ t: CGFloat, _ b: CGFloat) -> CGFloat { t * ta + b * (1 - ta) }
        return UIColor(red: mix(tr, br), green: mix(tg, bg), blue: mix(tb, bb), alpha: 1)
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ p: UILayoutPriority) -> NSLayoutConstraint { priority = p; return self }
}
