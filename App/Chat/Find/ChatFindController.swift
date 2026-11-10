import UIKit

/// Find in chat (parity 240 §5; S:build/fe-convo-gates.ts r1-46, r3-13, r4-84): ⋯ › Find opens a glass find bar under
/// the status line. It searches as typed (no capitals, no autocorrect, Return reads Search), counts the matches
/// ("2 of 5"), steps through them with ↑ (older) and ↓ (newer), and highlights them in the bubbles — every match
/// yellow, the current one orange — bringing the current one a third of the way down the room left.
final class ChatFindController: NSObject, UITextFieldDelegate {
    private weak var chat: ChatViewController?
    let bar = ChatFindBar()
    private(set) var query = ""
    private(set) var matches: [ChatFindMatch] = []
    private(set) var current: Int?
    private(set) var isActive = false
    /// Bubbles' searchable text, rebuilt when the messages change.
    private var units: [ChatFindUnit] = []
    private var unitsStale = true
    private var researchWork: DispatchWorkItem?

    init(chat: ChatViewController) {
        self.chat = chat
        super.init()
        bar.field.delegate = self
        bar.field.addAction(UIAction { [weak self] _ in self?.queryChanged() }, for: .editingChanged)
        bar.onPrevious = { [weak self] in self?.step(forward: false) }
        bar.onNext = { [weak self] in self?.step(forward: true) }
        bar.onDone = { [weak self] in self?.close() }
        bar.onEarlier = { [weak self] in self?.searchEarlier() }
    }

    // MARK: Opening and closing

    func open() {
        guard let chat else { return }
        if !isActive {
            isActive = true
            AppLog.trace("chatui", "find opened \(AppLog.tag(scope: chat.scope))")
            chat.showFindBar(bar)
        }
        unitsStale = true
        // After the ⋯ menu has handed focus back, so the field keeps it (and the keyboard comes up).
        DispatchQueue.main.async { [weak self] in self?.bar.field.becomeFirstResponder() }
        if !query.isEmpty { research(keepCurrent: true) }
        update()
    }

    func close() {
        guard isActive, let chat else { return }
        isActive = false
        AppLog.trace("chatui", "find closed \(AppLog.tag(scope: chat.scope))")
        bar.field.resignFirstResponder()
        query = ""
        bar.field.text = ""
        bar.textChanged()
        matches = []
        current = nil
        update()
        chat.hideFindBar(bar)
        chat.findHighlightsChanged()
    }

    // MARK: Searching

    private func queryChanged() {
        query = bar.field.text ?? ""
        researchWork?.cancel()
        // A short pause while typing: a long chat isn't searched on every key.
        let work = DispatchWorkItem { [weak self] in self?.research(keepCurrent: false) }
        researchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// The transcript changed while finding: the matches follow (the current one stays when it is still there).
    func messagesChanged() {
        unitsStale = true
        guard isActive, !ChatFind.normalized(query).isEmpty else { return }
        researchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.research(keepCurrent: true) }
        researchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func research(keepCurrent: Bool) {
        guard let chat else { return }
        if unitsStale {
            units = ChatFind.units(chat.session.messages)
            unitsStale = false
        }
        let previous = current.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
        var found: [ChatFindMatch] = []
        for unit in units {
            let count = ChatFind.ranges(of: query, in: unit.text).count
            for k in 0..<count { found.append(ChatFindMatch(rowId: unit.rowId, messageId: unit.messageId, occurrence: k)) }
        }
        matches = found
        current = ChatFind.keepCurrent(keepCurrent ? previous : nil, in: found)
        // Never the query itself: just how many turned up.
        AppLog.trace("chatui", "find \(AppLog.tag(scope: chat.scope)): \(matches.count) match(es)")
        update()
        chat.findHighlightsChanged()
        if !keepCurrent || previous == nil { reveal() }
    }

    /// Search Earlier Messages: Find searches what is loaded, so this pages the next older stretch in; the matches
    /// follow when it arrives (messagesChanged).
    private func searchEarlier() {
        guard let chat, chat.session.hasOlder, !chat.session.isLoadingOlder else { return }
        if let paging = chat.session as? ChatOlderPaging, paging.olderFailed { paging.retryOlder() } else { chat.session.loadOlder() }
        update()
    }

    /// The session's paging state changed (loading, failed, nothing older left): the bar's Search Earlier row follows.
    func sessionStateChanged() {
        guard isActive else { return }
        update()
    }

    /// [mac] Stress test 2026-10-28 #15: Edit › Find Next / Find Previous (⌘G / ⇧⌘G) have something to step to.
    var canStep: Bool { isActive && !matches.isEmpty }

    func step(forward: Bool) {
        guard !matches.isEmpty else { return }
        Haptics.play(.selection)
        current = ChatFind.step(current, count: matches.count, forward: forward)
        update()
        chat?.findHighlightsChanged()
        reveal()
    }

    private func reveal() {
        guard let current, matches.indices.contains(current) else { return }
        chat?.revealFindMatch(matches[current])
    }

    private func update() {
        let session = chat?.session
        let hasOlder = session?.hasOlder == true
        bar.setCount(ChatFind.countText(current: current, total: matches.count, query: query, hasOlder: hasOlder), canStep: !matches.isEmpty)
        let earlier: ChatFindBar.Earlier
        if !hasOlder || ChatFind.normalized(query).isEmpty { earlier = .hidden }
        else if session?.isLoadingOlder == true { earlier = .loading }
        else { earlier = .idle }
        bar.setEarlier(earlier)
    }

    // MARK: What a bubble highlights

    /// The query and which of this bubble's occurrences is the current one (nil: none here), or nil when nothing is found.
    func highlight(forRow rowId: String) -> ChatFindHighlight? {
        guard isActive, !ChatFind.normalized(query).isEmpty, !matches.isEmpty else { return nil }
        let place = current.flatMap { matches.indices.contains($0) ? drawnPlace(of: matches[$0]) : nil }
        return ChatFindHighlight(query: query, current: place?.rowId == rowId ? place?.occurrence : nil)
    }

    /// Where a match is drawn: the bubble that holds it and its occurrence counted across that bubble
    /// (`ChatFind.drawnPlace`, with the reply's built bubbles).
    func drawnPlace(of match: ChatFindMatch) -> (rowId: String, occurrence: Int) {
        ChatFind.drawnPlace(of: match, bubbleParts: chat?.findBubbleParts(ofMessage: match.messageId), units: units, query: query)
    }

    // MARK: UITextFieldDelegate

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        // Return reads Search: it steps to the next match (older to newer, as the arrows' ↓).
        step(forward: true)
        return false
    }
}

/// What a bubble draws for Find: every occurrence of `query`, the `current`-th in the current colour.
nonisolated struct ChatFindHighlight: Hashable, Sendable {
    var query: String
    var current: Int?

    static let matchColor = UIColor.systemYellow.withAlphaComponent(0.55)
    static let currentColor = UIColor.systemOrange
}

/// The find bar: a glass capsule with the search field, the count, ↑ ↓ and Done. When the text is too large for one
/// line to leave the field room (accessibility sizes, or a narrow phone at Extra Large) the count, ↑ ↓ and Done move
/// to a second line under the field. While earlier messages aren't loaded, Search Earlier Messages sits under them.
final class ChatFindBar: UIView {
    #if targetEnvironment(macCatalyst)
    /// [mac] Stress test 2026-10-28 #70 (round 2): a plain field with its own magnifier and ⓧ. The Mac's search field
    /// drew its ⓧ in the empty focused field whatever `clearButtonMode` said (setting `.never` while empty, round 1,
    /// changed nothing on screen), so the Mac's ⓧ is a right view this bar shows only over words.
    let field: UITextField = UITextField()
    private let clearButton = UIButton(type: .system)
    #else
    let field: UITextField = UISearchTextField()
    #endif
    private let countLabel = UILabel()
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private let earlierButton = UIButton(type: .system)
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onDone: (() -> Void)?
    var onEarlier: (() -> Void)?
    /// The bar's height changed (the second line, the Search Earlier row): the transcript's top inset follows.
    var onHeightChange: ((CGFloat) -> Void)?
    static let height: CGFloat = 48
    /// The narrowest the field may get beside the controls before they move to their own line.
    private static let minimumFieldWidth: CGFloat = 88
    private static let arrowWidth: CGFloat = 44

    /// Search Earlier Messages: not shown (nothing older, nothing typed), ready, or paging in.
    enum Earlier { case hidden, idle, loading }

    private let topRow = UIStackView()
    private let controlsRow = UIStackView()
    private let controlsSpacer = UIView()
    private var stacked = false
    private var reportedHeight: CGFloat = 0
    private var earlier: Earlier = .hidden

    private let glass: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        view.cornerConfiguration = .capsule()
        return view
    }()
    private var capsule = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "chat.find"
        addSubview(glass)
        glass.translatesAutoresizingMaskIntoConstraints = false
        field.placeholder = "Find in Chat"
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.returnKeyType = .search
        field.enablesReturnKeyAutomatically = true
        field.backgroundColor = .clear
        field.borderStyle = .none
        field.clearButtonMode = .whileEditing
        #if targetEnvironment(macCatalyst)
        // [mac] Stress test 2026-10-28 #70: the ⓧ shows only over words (`macField`).
        macField()
        #endif
        field.font = HQFont.preferred(.body)
        field.adjustsFontForContentSizeCategory = true
        field.accessibilityIdentifier = "chat.find.field"
        countLabel.font = HQFont.preferred(.footnote)
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textColor = ChatPalette.label2
        countLabel.accessibilityIdentifier = "chat.find.count"
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        configure(previousButton, symbol: "chevron.up", label: "Previous Match", identifier: "chat.find.previous") { [weak self] in self?.onPrevious?() }
        configure(nextButton, symbol: "chevron.down", label: "Next Match", identifier: "chat.find.next") { [weak self] in self?.onNext?() }
        var done = UIButton.Configuration.plain()
        done.title = "Done"
        #if targetEnvironment(macCatalyst)
        // [mac] Stress test 2026-10-28 #55 (round 6): the sheets' Done, one font (`MacCloseItem`).
        let doneFont = MacCloseItem.font(semibold: true)
        #else
        let doneFont = UIFont.menusFont(.body, weight: .semibold)
        #endif
        done.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a; a.font = doneFont; return a
        }
        done.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6)
        // [mac] Stress test 2026-10-28 #55: Done is the label colour, semibold, in both looks (was blue in one, black in the other).
        if DeviceWord.isMac { done.baseForegroundColor = HQPalette.label }
        doneButton.configuration = done
        doneButton.accessibilityIdentifier = "chat.find.done"
        doneButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        doneButton.addAction(UIAction { [weak self] _ in self?.onDone?() }, for: .primaryActionTriggered)
        earlierButton.accessibilityIdentifier = "chat.find.earlier"
        earlierButton.contentHorizontalAlignment = .leading
        earlierButton.isHidden = true
        earlierButton.addAction(UIAction { [weak self] _ in self?.onEarlier?() }, for: .primaryActionTriggered)
        setEarlier(.hidden)
        controlsSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controlsSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for row in [topRow, controlsRow] {
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 4
        }
        topRow.addArrangedSubview(field)
        controlsRow.addArrangedSubview(controlsSpacer)
        arrange(stacked: false)
        let column = UIStackView(arrangedSubviews: [topRow, controlsRow, earlierButton])
        column.axis = .vertical
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(column)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -8),
            column.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 4),
            column.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -4),
            topRow.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.height - 8),
            previousButton.widthAnchor.constraint(equalToConstant: Self.arrowWidth),
            nextButton.widthAnchor.constraint(equalToConstant: Self.arrowWidth),
            previousButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            nextButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.height),
        ])
        setCount("", canStep: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func configure(_ button: UIButton, symbol: String, label: String, identifier: String, action: @escaping () -> Void) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: .body, scale: .medium))
        config.contentInsets = .zero
        button.configuration = config
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
    }

    // MARK: One line or two

    /// One line: field, count, ↑ ↓, Done. Two: the field alone, then the count and ↑ ↓ Done under it.
    private func arrange(stacked: Bool) {
        self.stacked = stacked
        let controls: [UIView] = [countLabel, previousButton, nextButton, doneButton]
        for view in controls { view.removeFromSuperview() }
        let row = stacked ? controlsRow : topRow
        if stacked { row.insertArrangedSubview(countLabel, at: 0) } else { row.addArrangedSubview(countLabel) }
        for view in controls.dropFirst() { row.addArrangedSubview(view) }
        row.setCustomSpacing(10, after: countLabel)
        row.setCustomSpacing(0, after: previousButton)   // the arrows' 44 pt targets sit side by side
        controlsRow.isHidden = !stacked
    }

    /// Two lines at accessibility sizes, and whenever one line would leave the field narrower than it can be read in
    /// (measured with the longest count, so the bar doesn't change shape as the count does).
    private func wantsStacked(width: CGFloat) -> Bool {
        if traitCollection.preferredContentSizeCategory.isAccessibilityCategory { return true }
        guard width > 0 else { return stacked }
        let font = countLabel.font ?? HQFont.preferred(.footnote)
        let count = ceil(("No Results Yet" as NSString).size(withAttributes: [.font: font]).width)
        let controls = 4 + count + 10 + Self.arrowWidth * 2 + 4 + doneButton.intrinsicContentSize.width
        return width - 22 - controls < Self.minimumFieldWidth
    }

    /// One bar is reused across opens: forget the height it last reported once it leaves, so the next open reports it
    /// again (showFindBar starts the inset at one line's height).
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview == nil { reportedHeight = 0 }
    }

    override func layoutSubviews() {
        let wanted = wantsStacked(width: bounds.width)
        if wanted != stacked { arrange(stacked: wanted) }
        super.layoutSubviews()
        // A capsule while it is one line; a rounded card once it is taller, so the corners don't cut into the text.
        let isCapsule = bounds.height <= Self.height + 4
        if isCapsule != capsule {
            capsule = isCapsule
            glass.cornerConfiguration = isCapsule ? .capsule() : .corners(radius: .fixed(24))
        }
        if bounds.height > 0, abs(bounds.height - reportedHeight) > 0.5 {
            reportedHeight = bounds.height
            onHeightChange?(bounds.height)
        }
    }

    // MARK: State

    /// The field's words changed (typed, or emptied when Find closes). [mac] #70: the ⓧ shows only over words.
    func textChanged() {
        #if targetEnvironment(macCatalyst)
        let empty = (field.text ?? "").isEmpty
        if clearButton.isHidden != empty { clearButton.isHidden = empty }
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// [mac] Stress test 2026-10-28 #70: the Mac field's magnifier and its own ⓧ (the glass capsule is its box).
    private func macField() {
        field.clearButtonMode = .never
        // [mac] Mac polish #69: "Find in Chat" in the look's label 2, as the bars' search fields have it; the system's
        // placeholder grey read at about 2:1.
        field.attributedPlaceholder = NSAttributedString(string: field.placeholder ?? "", attributes: [.foregroundColor: HQPalette.label2])
        // [mac] Stress test 2026-10-28 #70 (round 6): the magnifier was the system's footnote size (about 10 px beside
        // 20 pt words) with the caret against it. Now a search field's: about the words' cap height (the field's body
        // font, with UI Scale), 8 pt in from the edge and 6 pt clear of the text.
        let font = HQFont.preferred(.body)
        let glassSymbol = UIImage(systemName: "magnifyingglass",
                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: (font.pointSize * 0.82).rounded(), weight: .medium))
        let magnifier = UIImageView(image: glassSymbol)
        magnifier.tintColor = HQPalette.label2
        magnifier.contentMode = .center
        let glyph = magnifier.intrinsicContentSize
        let lead: CGFloat = 8, gap: CGFloat = 6
        let holder = UIView(frame: CGRect(x: 0, y: 0, width: lead + glyph.width + gap, height: max(22, glyph.height)))
        magnifier.frame = CGRect(x: lead, y: (holder.bounds.height - glyph.height) / 2, width: glyph.width, height: glyph.height)
        holder.isUserInteractionEnabled = false
        holder.addSubview(magnifier)
        field.leftView = holder
        field.leftViewMode = .always
        var clear = UIButton.Configuration.plain()
        clear.image = UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote))
        clear.baseForegroundColor = HQPalette.label3
        clear.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 6)
        clearButton.configuration = clear
        clearButton.accessibilityLabel = "Clear Text"
        clearButton.accessibilityIdentifier = "chat.find.clear"
        clearButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.field.text = ""
            self.field.sendActions(for: .editingChanged)
            self.textChanged()
        }, for: .primaryActionTriggered)
        field.rightView = clearButton
        field.rightViewMode = .always
        field.addAction(UIAction { [weak self] _ in self?.textChanged() }, for: .editingChanged)
        textChanged()
    }
    #endif

    private var announced = ""

    func setCount(_ text: String, canStep: Bool) {
        countLabel.text = text
        countLabel.isHidden = text.isEmpty
        previousButton.isEnabled = canStep
        nextButton.isEnabled = canStep
        if !text.isEmpty, text != announced {
            announced = text
            HQAnnounce.say(text)
        }
    }

    /// Find searches only the loaded messages: this row says so and pages the earlier ones in.
    func setEarlier(_ state: Earlier) {
        guard state != earlier || earlierButton.configuration == nil else { return }
        earlier = state
        var config = UIButton.Configuration.plain()
        config.title = state == .loading ? "Loading Earlier Messages…" : "Search Earlier Messages"
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a; a.font = UIFont.menusFont(.footnote, weight: .semibold); return a
        }
        config.showsActivityIndicator = state == .loading
        config.imagePadding = 6
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 6, trailing: 4)
        earlierButton.configuration = config
        earlierButton.isEnabled = state == .idle
        let hidden = state == .hidden
        if earlierButton.isHidden != hidden { earlierButton.isHidden = hidden }
    }
}
