import UIKit

/// A request's helpers, including earlier batches. Reports and delegate calls stay one tap away in the same sheet.
final class HelperStatusSheetViewController: UIViewController {
    let body = SubagentsBody(panel: true)
    var onVisibilityChange: (() -> Void)?
    var onLayout: (() -> Void)?
    private(set) var isVisible = false
    private let scroll = UIScrollView()
    private let reportsButton = UIButton(type: .system)
    private let reports: UpdatesSheetViewController
    private var timer: Timer?
    private var lastWidth: CGFloat = 0

    init(reports: UpdatesSheetViewController) {
        self.reports = reports
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HQPalette.sheetPage
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        body.accessibilityIdentifier = "chat.helpers.details"
        reportsButton.setTitle("Reports & Steps", for: .normal)
        reportsButton.titleLabel?.font = HQFont.preferred(.body)
        reportsButton.titleLabel?.adjustsFontForContentSizeCategory = true
        reportsButton.contentHorizontalAlignment = .leading
        reportsButton.accessibilityIdentifier = "chat.helpers.reports"
        reportsButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.reports.title = "Reports & Steps"
            self.navigationController?.pushViewController(self.reports, animated: true)
        }, for: .touchUpInside)
        reportsButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(reportsButton)
        scroll.addSubview(body)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            reportsButton.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            reportsButton.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            reportsButton.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
            reportsButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            body.topAnchor.constraint(equalTo: reportsButton.bottomAnchor, constant: 8),
            body.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
            body.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if abs(lastWidth - body.bounds.width) > 0.5 {
            lastWidth = body.bounds.width
            onLayout?()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        onVisibilityChange?()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.body.tick(now: Date().timeIntervalSince1970) }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isVisible = false
        timer?.invalidate()
        timer = nil
        onVisibilityChange?()
    }

    func update(title: String, reports opened: UpdatesOpened) {
        navigationItem.subtitle = title
        reports.update(opened)
        reportsButton.isHidden = opened.members.isEmpty
    }

    #if DEBUG
    var debugReports: UpdatesSheetViewController { reports }
    #endif
}

// [updates] The sheet a group's line opens (UpdateGroups.swift): the run in the order it happened, each member on a
// card of its own beside a rail, as the Steps sheet draws a reply's steps. A message shows its whole words in the
// reply's type (a long one shows its first lines and "Show More"); a work line lists its steps, each opening its
// step sheet inside this one; "5 files changed" lists its files and Review Changes; a note is its line.
//
// Until 2026-11-17 the members opened in the chat itself: a grey card under the line, one row per member cut at two
// lines, each row opening again inside the card, the chat pushed apart by all of it (owner: "When you click it to
// open it all it's so messy. This must be perfect."). Here nothing in the chat moves, nothing is cut mid-sentence
// that a tap elsewhere has to finish, and the sheet is as tall as what it holds. It is presented through
// `ChatSheet.wrap(` (ChatViewController+Updates.swift), so it sits on the app's Liquid Glass with its cards solid, at
// its fitted height too.

final class UpdatesSheetViewController: UITableViewController {
    /// What the sheet needs of the chat that opened it.
    struct Hooks {
        /// A step's own page, pushed inside this sheet.
        var stepPage: (_ messageId: String, _ call: ToolCall) -> UIViewController?
        /// Every step of a work line with more than `UpdateCardCell.stepLimit`: the Steps list, pushed here.
        var stepsPage: (_ messageId: String, _ calls: [ToolCall]) -> UIViewController?
        var openFile: (_ path: String) -> Void
        var reviewChanges: () -> Void
        var openLink: (_ url: URL, _ from: UIViewController) -> Void
        /// Held: Copy, Read Aloud and Share of a member's words; nil for a member without words.
        var menu: (_ member: UpdateMemberRow, _ source: UIView) -> UIMenu?
    }

    private var opened: UpdatesOpened
    private let hooks: Hooks
    /// Long members showing all their words.
    private var whole: Set<String> = []
    /// The member the sheet opens at (Find landed on a folded reply): in view, its card marked for a moment.
    private var focus: String?
    private var laidWidth: CGFloat = 0
    private var fitted: CGFloat = -1

    init(opened: UpdatesOpened, focus: String?, hooks: Hooks) {
        self.opened = opened
        self.focus = focus
        self.hooks = hooks
        if let focus { whole.insert(focus) }
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = HQPalette.sheetPage
        tableView.register(UpdateCardCell.self, forCellReuseIdentifier: "member")
        tableView.accessibilityIdentifier = "updates.list"
        tableView.separatorStyle = .none
        tableView.sectionHeaderTopPadding = 0
        tableView.sectionHeaderHeight = 0
        tableView.allowsSelection = false
        tableView.tableHeaderView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 4))
        tableView.tableFooterView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 12))
        navigationItem.subtitle = opened.subtitle
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (page: UpdatesSheetViewController, _) in
            page.tableView.reloadData()
        }
    }

    /// The chat moved on while the sheet was open (a helper finished, another message between the bots).
    func update(_ next: UpdatesOpened) {
        guard next.fingerprint != opened.fingerprint else { return }
        let grew = next.members.count > opened.members.count
        let atEnd = isViewLoaded && tableView.contentOffset.y + tableView.bounds.height >= tableView.contentSize.height - 40
        opened = next
        title = next.title
        navigationItem.subtitle = next.subtitle
        guard isViewLoaded else { return }
        tableView.reloadData()
        fitSheet()
        // A reader at the end follows what arrives; one reading further up keeps their place.
        if grew, atEnd, !next.members.isEmpty {
            tableView.layoutIfNeeded()
            tableView.scrollToRow(at: IndexPath(row: next.members.count - 1, section: 0), at: .bottom, animated: !HQMotion.reduced)
        }
    }

    /// Brings a member into view and marks its card (Find's next match in a sheet that is already open).
    func show(_ id: String) {
        whole.insert(id)
        focus = id
        guard isViewLoaded else { return }
        if navigationController?.topViewController !== self { navigationController?.popToViewController(self, animated: false) }
        tableView.reloadData()
        view.setNeedsLayout()
    }

    /// The sheet's height is settled before it comes up, so it rises straight to it.
    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        laidWidth = tableView.bounds.width
        tableView.reloadData()
        fitSheet(animated: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The words are laid out for the card's width: again when the sheet's width changes (a turned phone, the Mac).
        if abs(tableView.bounds.width - laidWidth) > 0.5 {
            laidWidth = tableView.bounds.width
            tableView.reloadData()
        }
        fitSheet()
        if let id = focus, let row = opened.members.firstIndex(where: { $0.id == id }), view.window != nil {
            focus = nil
            tableView.layoutIfNeeded()
            let path = IndexPath(row: row, section: 0)
            tableView.scrollToRow(at: path, at: .top, animated: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                (self?.tableView.cellForRow(at: path) as? UpdateCardCell)?.flash()
            }
        }
    }

    /// The share of the screen's sheet room a sheet may take and still be only as tall as its cards.
    private static let fitShare: CGFloat = 0.72

    /// The sheet is exactly as tall as its cards when they fit in most of the screen (two short messages don't open
    /// half a screen of empty glass, and five don't need a pull to see the fifth); a longer run opens at half height
    /// and pulls up to the whole.
    private func fitSheet(animated: Bool = true) {
        guard let navigation = navigationController, navigation.viewControllers.first === self,
              let sheet = navigation.sheetPresentationController, navigation.modalPresentationStyle == .pageSheet,
              !HQAccessibility.current.isAccessibilitySize else { return }
        tableView.layoutIfNeeded()
        // A detent's height leaves out the bottom safe area; the list starts under the sheet's bar.
        let needed = ceil(tableView.contentSize.height + tableView.adjustedContentInset.top + 4)
        guard abs(needed - fitted) > 0.5 else { return }
        fitted = needed
        let share = Self.fitShare
        let fit = UISheetPresentationController.Detent.custom(identifier: .init("updates.fit")) { context in
            needed <= context.maximumDetentValue * share ? needed : nil
        }
        let half = UISheetPresentationController.Detent.custom(identifier: .medium) { context in
            needed <= context.maximumDetentValue * share ? nil : context.maximumDetentValue * 0.5
        }
        let whole = UISheetPresentationController.Detent.custom(identifier: .large) { context in
            needed <= context.maximumDetentValue * share ? nil : context.maximumDetentValue
        }
        if animated, view.window != nil {
            sheet.animateChanges { sheet.detents = [fit, half, whole] }
        } else {
            sheet.detents = [fit, half, whole]
        }
    }

    // MARK: Rows

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { opened.members.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "member", for: indexPath) as! UpdateCardCell
        let member = opened.members[indexPath.row]
        let margins = tableView.layoutMargins.left + tableView.layoutMargins.right
        cell.configure(member, first: indexPath.row == 0, last: indexPath.row == opened.members.count - 1,
                       whole: whole.contains(member.id), width: tableView.bounds.width - margins,
                       style: ChatStyleCache.shared.style(for: traitCollection.preferredContentSizeCategory))
        cell.onMore = { [weak self] in self?.toggleWhole(member.id) }
        cell.onStep = { [weak self] index in self?.openStep(member, index) }
        cell.onLink = { [weak self] url in if let self { self.hooks.openLink(url, self) } }
        cell.menu = { [weak self] source in self?.hooks.menu(member, source) }
        return cell
    }

    private func toggleWhole(_ id: String) {
        Haptics.play(.selection)
        if whole.contains(id) { whole.remove(id) } else { whole.insert(id) }
        guard let row = opened.members.firstIndex(where: { $0.id == id }) else { return }
        let path = IndexPath(row: row, section: 0)
        if HQMotion.reduced {
            UIView.performWithoutAnimation { tableView.reloadRows(at: [path], with: .none) }
        } else {
            tableView.reloadRows(at: [path], with: .fade)
        }
        fitSheet()
    }

    private func openStep(_ member: UpdateMemberRow, _ index: Int) {
        if !member.files.isEmpty {
            // [files] One of its files, or its last row, Review Changes.
            if index < member.files.count { hooks.openFile(member.files[index].path) } else { hooks.reviewChanges() }
            return
        }
        let shown = UpdateCardCell.shownSteps(member)
        let page = index < shown.count ? hooks.stepPage(member.messageId, shown[index])
            : hooks.stepsPage(member.messageId, member.steps)
        guard let page else { return }
        Haptics.play(.selection)
        navigationController?.pushViewController(page, animated: true)
    }

    #if DEBUG
    /// Tests: the members shown, and the cards on screen.
    var debugMembers: [UpdateMemberRow] { opened.members }
    #endif
}

/// One member of the run: its face or glyph on the rail, its card beside it.
final class UpdateCardCell: UITableViewCell, UIContextMenuInteractionDelegate {
    /// A work line lists this many steps; a longer one adds "All 12 Steps", which opens the Steps list.
    static let stepLimit = 6
    /// A message longer than `clampOver` lines of the reply's type shows `clampLines` of them and "Show More".
    static let clampOver = 10, clampLines = 7

    static func shownSteps(_ member: UpdateMemberRow) -> [ToolCall] {
        member.steps.count > stepLimit ? Array(member.steps.prefix(stepLimit - 1)) : member.steps
    }

    var onMore: (() -> Void)?
    var onStep: ((Int) -> Void)?
    var onLink: ((URL) -> Void)?
    var menu: ((UIView) -> UIMenu?)?

    private let card = UIView()
    private let wash = UIView()
    private let badge = UIView()
    private let glyph = CAShapeLayer()
    private var head: HeadView?
    private let railUp = UIView()
    private let railDown = UIView()
    private let titleLabel = UILabel()
    private let timeLabel = UILabel()
    private let words = TextDrawView()
    private let wordsClip = UIView()
    private let fade = CAGradientLayer()
    private let more = UIButton(type: .system)
    private let rows = UIStackView()
    private let column = UIStackView()
    private var columnBottom: NSLayoutConstraint!
    private var wordsHeight: NSLayoutConstraint!
    private var wordsWidth: NSLayoutConstraint!
    private var currentGlyph: ChatGlyph?
    private var clamped = false
    private weak var linkTap: UITapGestureRecognizer?

    private static var badgeSide: CGFloat { HQFont.symbolSize(30, like: .body, cap: 44) }
    private static let cardPadding: CGFloat = 12
    private static let cardGap: CGFloat = 6
    private static let badgeGap: CGFloat = 10

    /// The room a card's words have in a list `width` wide between its margins.
    static func textWidth(_ width: CGFloat) -> CGFloat {
        max(0, width - badgeSide - badgeGap - 2 * (cardPadding + 2))
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundConfiguration = .clear()
        selectionStyle = .none
        let side = Self.badgeSide
        badge.layer.cornerRadius = side / 2
        badge.layer.cornerCurve = .circular
        glyph.fillColor = nil
        glyph.lineWidth = 1.5
        glyph.lineCap = .round
        glyph.lineJoin = .round
        badge.layer.addSublayer(glyph)
        for rail in [railUp, railDown] { rail.backgroundColor = ChatPalette.separator }
        card.layer.cornerCurve = .continuous
        wash.isUserInteractionEnabled = false
        wash.alpha = 0
        wash.layer.cornerCurve = .continuous

        titleLabel.font = HQFont.style(.subheadline, weight: .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = ChatPalette.label
        titleLabel.numberOfLines = 0
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timeLabel.font = HQFont.digits(13, like: .footnote)
        timeLabel.adjustsFontForContentSizeCategory = true
        timeLabel.textColor = HQPalette.cardNote
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let headRow = UIStackView(arrangedSubviews: [titleLabel, timeLabel])
        headRow.spacing = 8
        headRow.alignment = .firstBaseline

        wordsClip.clipsToBounds = true
        words.translatesAutoresizingMaskIntoConstraints = false
        wordsClip.addSubview(words)
        words.isAccessibilityElement = true
        words.accessibilityTraits = .staticText
        words.accessibilityIdentifier = "updates.words"
        // A cut message fades out over its last line, into "Show More".
        fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        fade.locations = [0, 0.78, 1]

        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 2, trailing: 0)
        more.configuration = config
        more.contentHorizontalAlignment = .leading
        more.accessibilityIdentifier = "updates.more"
        more.addAction(UIAction { [weak self] _ in self?.onMore?() }, for: .touchUpInside)
        #if targetEnvironment(macCatalyst)
        PointerEffects.outline(more) { [weak more] in
            guard let more, !more.bounds.isEmpty else { return nil }
            let box = more.titleLabel.flatMap { $0.bounds.isEmpty ? nil : $0.convert($0.bounds, to: more).insetBy(dx: -6, dy: -2) }
                ?? more.bounds.insetBy(dx: -6, dy: 0)
            return PointerEffects.Outline(rect: box, radius: MacSelection.radius, strong: false)
        }
        #endif

        rows.axis = .vertical
        column.axis = .vertical
        column.spacing = 4
        for v in [headRow, wordsClip, more, rows] as [UIView] { column.addArrangedSubview(v) }

        for v in [card, wash, railUp, railDown, badge, column] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false }
        contentView.addSubview(railUp)
        contentView.addSubview(railDown)
        contentView.addSubview(badge)
        contentView.addSubview(card)
        card.addSubview(wash)
        card.addSubview(column)
        let margins = contentView.layoutMarginsGuide
        let pad = Self.cardPadding
        wordsHeight = wordsClip.heightAnchor.constraint(equalToConstant: 0)
        wordsWidth = words.widthAnchor.constraint(equalToConstant: 0)
        columnBottom = column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -pad)
        let wordsBottom = words.bottomAnchor.constraint(equalTo: wordsClip.bottomAnchor)
        wordsBottom.priority = .defaultLow   // the clip is shorter than a cut message's words
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: side),
            badge.heightAnchor.constraint(equalTo: badge.widthAnchor),
            badge.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            // The badge sits centred on the card's first line of words, as a step's does.
            badge.centerYAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor, constant: -titleLabel.font.capHeight / 2),
            railUp.widthAnchor.constraint(equalToConstant: 2),
            railUp.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            railUp.topAnchor.constraint(equalTo: contentView.topAnchor),
            railUp.bottomAnchor.constraint(equalTo: badge.topAnchor, constant: -4),
            railDown.widthAnchor.constraint(equalToConstant: 2),
            railDown.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            railDown.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 4),
            railDown.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.cardGap / 2),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Self.cardGap / 2),
            card.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: Self.badgeGap),
            card.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            wash.topAnchor.constraint(equalTo: card.topAnchor),
            wash.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            wash.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            wash.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            column.topAnchor.constraint(equalTo: card.topAnchor, constant: pad),
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad + 2),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad - 2),
            words.topAnchor.constraint(equalTo: wordsClip.topAnchor),
            words.leadingAnchor.constraint(equalTo: wordsClip.leadingAnchor),
            wordsWidth, wordsBottom, wordsHeight, columnBottom,
        ])

        // Held: Copy, Read Aloud and Share of the member's words.
        card.addInteraction(UIContextMenuInteraction(delegate: self))
        // A link in the words opens.
        let links = UITapGestureRecognizer(target: self, action: #selector(linkTapped(_:)))
        links.cancelsTouchesInView = false
        card.addGestureRecognizer(links)
        linkTap = links
        #if targetEnvironment(macCatalyst)
        card.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(linkHover(_:))))
        // The words select with a drag, as a reply's do (ChatTextSelection.swift).
        textSelector = ChatTextSelector(host: card, owner: self, surfaces: { [weak self] in
            guard let self, !self.wordsClip.isHidden else { return [] }
            return [self.words]
        }, color: { DesktopFrost.tint(ChatPalette.tint) })
        #endif
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self, UITraitAccessibilityContrast.self,
                                 GlassSheetTrait.self]) { (cell: UpdateCardCell, _) in cell.paint() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ member: UpdateMemberRow, first: Bool, last: Bool, whole: Bool, width: CGFloat, style: ChatStyle) {
        railUp.isHidden = first
        railDown.isHidden = last
        titleLabel.text = member.title
        let time = UpdateTimes.words(member)
        timeLabel.text = time
        timeLabel.isHidden = time == nil

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = Self.badgeSide
        switch member.mark {
        case .glyph(let g):
            glyph.isHidden = false
            head?.isHidden = true
            let size = (side * 0.5).rounded()
            glyph.frame = CGRect(x: (side - size) / 2, y: (side - size) / 2, width: size, height: size)
            if currentGlyph != g || glyph.path == nil { glyph.path = g.path(size: size) }
            currentGlyph = g
        case .face(let sender):
            glyph.isHidden = true
            let view = head ?? {
                let made = HeadView(side: side, mark: true)
                made.isUserInteractionEnabled = false
                badge.addSubview(made)
                head = made
                return made
            }()
            view.isHidden = false
            view.frame = CGRect(x: 0, y: 0, width: side, height: side)
            view.configure(raw: sender.head, profile: sender.profile)
        }
        CATransaction.commit()
        faced = { if case .face = member.mark { return true } else { return false } }()

        // The words: a message's whole text, or a work line's thought, in the reply's type.
        let textWidth = Self.textWidth(width)
        var text: NSAttributedString?
        if !member.full.isEmpty {
            text = TextLayout.resultText(member.full, links: member.process ? .addresses : .formatted, style: style)
        } else if let thought = member.thought, !thought.isEmpty {
            text = TextLayout.resultText(thought, links: .none, style: style)
        }
        clamped = false
        if let text {
            let layout = TextKitLayout(text, width: textWidth)
            words.set(layout: layout)
            words.accessibilityLabel = text.string
            wordsWidth.constant = layout.size.width
            let lineHeight = ceil(style.tool.lineHeight)
            let long = layout.size.height > lineHeight * CGFloat(Self.clampOver)
            clamped = long && !whole
            wordsHeight.constant = clamped ? lineHeight * CGFloat(Self.clampLines) : layout.size.height
            wordsClip.isHidden = false
            more.isHidden = !long
            var config = more.configuration
            config?.attributedTitle = AttributedString(whole ? "Show Less" : "Show More", attributes: AttributeContainer([
                .font: HQFont.style(.footnote, weight: .semibold),
            ]))
            more.configuration = config
            more.accessibilityValue = whole ? "Expanded" : "Collapsed"
        } else {
            words.set(layout: nil)
            wordsClip.isHidden = true
            more.isHidden = true
        }
        wordsClip.layer.mask = clamped ? fade : nil
        #if targetEnvironment(macCatalyst)
        textSelector?.refresh()
        #endif

        configureRows(member, style: style)
        // A card with only its title (a note, a one-line work line) keeps the title centred in it.
        // Rows bring their own 7 pt above and below their words: the card's edge and its title keep their distance.
        let onlyRows = wordsClip.isHidden && !rows.isHidden
        column.setCustomSpacing(wordsClip.isHidden && rows.isHidden ? 0 : onlyRows ? 2 : 4, after: column.arrangedSubviews[0])
        columnBottom.constant = rows.isHidden ? -Self.cardPadding : -(Self.cardPadding - 7)

        isAccessibilityElement = false
        titleLabel.accessibilityLabel = [member.title, time].compactMap { $0 }.joined(separator: ", ")
        accessibilityIdentifier = "updates.member"   // on the cell: a plain view's never reaches the accessibility tree
        paint()
        setNeedsLayout()
    }

    private var faced = false

    /// A work line's steps, or a files member's files and Review Changes: a row each, opening its page.
    private func configureRows(_ member: UpdateMemberRow, style: ChatStyle) {
        struct Line { var glyph: ChatGlyph; var title: String; var detail: String?; var failed = false; var action = false }
        var lines: [Line] = []
        if !member.files.isEmpty {
            lines = member.files.map { Line(glyph: .file, title: $0.name, detail: UpdateCardCell.fileCounts($0)) }
            lines.append(Line(glyph: .explore, title: "Review Changes", detail: nil, action: true))
        } else if !member.steps.isEmpty {
            for call in Self.shownSteps(member) {
                let title = ChatRunSummary.summarize([call], live: false)
                lines.append(Line(glyph: Self.stepGlyph(title), title: title, detail: Self.detail(call, title: title),
                                  failed: call.state == .failed))
            }
            if member.steps.count > Self.stepLimit {
                lines.append(Line(glyph: .other, title: "All \(member.steps.count) Steps", detail: nil, action: true))
            }
        }
        rows.isHidden = lines.isEmpty
        while rows.arrangedSubviews.count < lines.count {
            let row = UpdateStepRow()
            row.tag = rows.arrangedSubviews.count
            row.addTarget(self, action: #selector(stepTapped(_:)), for: .touchUpInside)
            rows.addArrangedSubview(row)
        }
        for (i, view) in rows.arrangedSubviews.enumerated() {
            guard let row = view as? UpdateStepRow else { continue }
            row.isHidden = i >= lines.count
            guard i < lines.count else { continue }
            let line = lines[i]
            row.configure(glyph: line.glyph, title: line.title, detail: line.detail, failed: line.failed, action: line.action,
                          rule: i > 0)
        }
    }

    /// [files] A file's edits and lines after its name ("2 edits · +3 −1"); nil when its diffs counted nothing.
    static func fileCounts(_ file: ChangedFile) -> String? {
        var parts: [String] = []
        if file.edits > 1 { parts.append("\(file.edits) edits") }
        let lines = [file.added > 0 ? "+\(file.added)" : nil, file.removed > 0 ? "−\(file.removed)" : nil].compactMap { $0 }
        if !lines.isEmpty { parts.append(lines.joined(separator: " ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A step's glyph: a delegated task is a helper's work, so it takes the helpers' small bot, as their rows and the
    /// line's mark do (review 2026-10-28: a wrench beside "Delegated 1 task").
    static func stepGlyph(_ summary: String) -> ChatGlyph {
        summary.hasPrefix("Delegat") ? .subagent : ChatRunSummary.glyph(forSummary: summary)
    }

    /// What a step worked on, after what it did: its own words when they say more than its summary, else the command,
    /// path, query or address it was given ("Ran 1 command  date; mail status").
    static func detail(_ call: ToolCall, title: String) -> String? {
        let words = ChatText.trimmed(call.title)
        // "Edited TASK.json" beside the step's own "Edit TASK.json" says it twice.
        func repeats(_ value: String) -> Bool {
            let last = (value as NSString).lastPathComponent.components(separatedBy: " ").last ?? value
            return !last.isEmpty && title.localizedCaseInsensitiveContains(last)
        }
        if !words.isEmpty, words != call.name, words != title { return repeats(words) ? nil : words }
        let args = ToolArgs.parse(call.argsText)
        for key in ["command", "path", "file_path", "query", "url", "goal"] {
            if let value = args[key]?.string, !ChatText.trimmed(value).isEmpty {
                // "Edited overview.md" already names notes/overview.md.
                if title.contains((value as NSString).lastPathComponent) { return nil }
                return ChatText.trimmed(value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression))
            }
        }
        return nil
    }

    /// The card's and the badge's fill, as a step's card in the Steps sheet (`StepLineCell`).
    private var fill: UIColor {
        if GlassSheetKit.designed { return HQPalette.sheetCard }
        return Theme.isDesktop ? .clear : HQPalette.card
    }

    private func paint() {
        let ink = (Theme.isDesktop ? HQPalette.stroke : GlassSheetKit.designed ? HQPalette.glassEdge : nil)?
            .resolvedColor(with: traitCollection).cgColor
        let edge = ink.flatMap { $0.alpha > 0 ? $0 : nil }
        let radius: CGFloat = GlassSheetKit.designed ? 20 : Theme.isDesktop ? min(16, ProjectCard.radius) : 12
        card.backgroundColor = fill
        card.layer.cornerRadius = radius
        card.layer.borderWidth = edge == nil ? 0 : HQShape.hairline
        card.layer.borderColor = edge
        wash.layer.cornerRadius = radius
        wash.backgroundColor = ChatPalette.tint.withAlphaComponent(0.16)
        // A face is its own badge; a glyph sits on the cards' fill, inside their edge.
        badge.backgroundColor = faced ? .clear : fill
        badge.layer.borderWidth = faced || edge == nil ? 0 : 1
        badge.layer.borderColor = edge
        glyph.strokeColor = ChatPalette.label2.resolvedColor(with: traitCollection).cgColor
        more.tintColor = ChatPalette.tintText
        for case let row as UpdateStepRow in rows.arrangedSubviews { row.paint() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = wordsClip.bounds
        CATransaction.commit()
    }

    /// Find landed here: the card is marked for a moment.
    func flash() {
        wash.alpha = 1
        UIView.animate(withDuration: 0.9, delay: 0.5, options: [.allowUserInteraction]) { self.wash.alpha = 0 }   // motion-ok: colour only
    }

    @objc private func stepTapped(_ sender: UIControl) { onStep?(sender.tag) }

    // MARK: Links

    private func link(at gr: UIGestureRecognizer) -> URL? {
        guard !wordsClip.isHidden else { return nil }
        let p = gr.location(in: words)
        guard wordsClip.bounds.contains(gr.location(in: wordsClip)) else { return nil }
        return words.bounds.insetBy(dx: -6, dy: -6).contains(p) ? words.link(at: p) : nil
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === linkTap { return link(at: gestureRecognizer) != nil }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    @objc private func linkTapped(_ gr: UITapGestureRecognizer) {
        guard let url = link(at: gr) else { return }
        onLink?(url)
    }

    // MARK: Held

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        let held = menu?(card)
        #if targetEnvironment(macCatalyst)
        // With part of the words selected, Copy Selection takes that part, ahead of the member's own menu.
        if let selected = textSelector?.selectedText {
            held.map(ChatTextSelector.nameWholeCopy)
            let copy = UIAction(title: "Copy Selection", image: UIImage(systemName: "text.cursor")) { _ in
                UIPasteboard.general.string = selected
                Haptics.play(.success)
            }
            copy.accessibilityIdentifier = "selection.copy"
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                UIMenu(children: [copy] + (held.map { [UIMenu(options: .displayInline, children: $0.children)] } ?? []))
            }
        }
        #endif
        guard let held else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in held }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        // The whole card lifts, with its own corners.
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(roundedRect: card.bounds, cornerRadius: card.layer.cornerRadius)
        return UITargetedPreview(view: card, parameters: parameters)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        wash.layer.removeAllAnimations()
        wash.alpha = 0
        #if targetEnvironment(macCatalyst)
        textSelector?.clear()
        #endif
    }

    #if targetEnvironment(macCatalyst)
    // MARK: [mac] Selecting the words

    private var textSelector: ChatTextSelector?
    private var pointerOnLink = false

    @objc private func linkHover(_ recognizer: UIHoverGestureRecognizer) {
        let inside = recognizer.state == .began || recognizer.state == .changed
        let onLink = inside && link(at: recognizer) != nil
        if onLink { MacWindow.cursor("pointingHandCursor") } else if pointerOnLink { MacWindow.cursor("arrowCursor") }
        pointerOnLink = onLink
    }

    override var canBecomeFirstResponder: Bool { textSelector?.hasSelection ?? false }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) { return textSelector?.selectedText != nil }
        if action == #selector(selectAll(_:)) { return textSelector?.isActive ?? false }
        return super.canPerformAction(action, withSender: sender)
    }

    override func copy(_ sender: Any?) { textSelector?.copySelection() }

    override func selectAll(_ sender: Any?) { textSelector?.selectAll() }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { textSelector?.clear(resign: false) }
        return resigned
    }
    #endif

    #if DEBUG
    var debugWords: String? { wordsClip.isHidden ? nil : words.accessibilityLabel }
    var debugClamped: Bool { clamped }
    var debugRows: [String] { rows.arrangedSubviews.filter { !$0.isHidden }.compactMap { $0.accessibilityLabel } }
    #endif
}

/// One line inside a member's card: a step ("Ran 1 command  date; mail status"), a file ("analyze.py  2 edits · +3 −1"),
/// or the card's own action ("Review Changes", "All 12 Steps"). It opens its page.
final class UpdateStepRow: UIControl {
    private let rule = UIView()
    private let glyph = CAShapeLayer()
    private let glyphHost = UIView()
    private let words = UILabel()
    private let failedLabel = UILabel()
    private let chevron = UIImageView()
    private var action = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        glyph.fillColor = nil
        glyph.lineWidth = 1.5
        glyph.lineCap = .round
        glyph.lineJoin = .round
        glyphHost.layer.addSublayer(glyph)
        glyphHost.isUserInteractionEnabled = false
        // One line: what it did, then on what, cut at the edge (the step's page has the whole of it).
        words.numberOfLines = 1
        words.lineBreakMode = .byTruncatingTail
        words.adjustsFontForContentSizeCategory = true
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        failedLabel.text = "Failed"
        failedLabel.font = HQFont.style(.footnote)
        failedLabel.adjustsFontForContentSizeCategory = true
        failedLabel.textColor = ChatPalette.red
        failedLabel.setContentHuggingPriority(.required, for: .horizontal)
        failedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        chevron.image = UIImage(systemName: "chevron.right",
                                withConfiguration: UIImage.SymbolConfiguration(font: HQFont.style(.caption1, weight: .semibold)))
        chevron.contentMode = .center
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        let side = HQFont.symbolSize(16, like: .subheadline, cap: 24)
        let stack = UIStackView(arrangedSubviews: [glyphHost, words, failedLabel, chevron])
        stack.spacing = 8
        stack.alignment = .center
        stack.isUserInteractionEnabled = false
        for v in [rule, stack, glyphHost] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(rule)
        addSubview(stack)
        NSLayoutConstraint.activate([
            glyphHost.widthAnchor.constraint(equalToConstant: side),
            glyphHost.heightAnchor.constraint(equalToConstant: side),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: words.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: HQShape.hairline),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "updates.step"
        #if targetEnvironment(macCatalyst)
        // Extend 8 pt past the icon and chevron into the card's 14 pt padding so the highlight breathes evenly.
        PointerEffects.outline(self) { [weak self] in
            guard let self, !self.bounds.isEmpty else { return nil }
            return PointerEffects.Outline(rect: self.bounds.insetBy(dx: -8, dy: 1), radius: MacSelection.radius, strong: false)
        }
        #endif
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        #if targetEnvironment(macCatalyst)
        PointerEffects.outlineDidLayout(self)
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(glyph g: ChatGlyph, title: String, detail: String?, failed: Bool, action: Bool, rule shown: Bool) {
        self.action = action
        rule.isHidden = !shown
        let side = HQFont.symbolSize(16, like: .subheadline, cap: 24)
        glyph.frame = CGRect(x: 0, y: 0, width: side, height: side)
        glyph.path = g.path(size: side)
        glyphHost.isHidden = action
        let font = HQFont.style(.subheadline, weight: action ? .semibold : nil)
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: font, .foregroundColor: action ? ChatPalette.tintText : ChatPalette.label,
        ])
        if let detail {
            text.append(NSAttributedString(string: "  " + detail, attributes: [.font: font, .foregroundColor: HQPalette.cardNote]))
        }
        words.attributedText = text
        // [a11y] At the accessibility sizes one line holds two words: it wraps there.
        words.numberOfLines = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 3 : 1
        failedLabel.isHidden = !failed
        accessibilityLabel = [title, detail, failed ? "Failed" : nil].compactMap { $0 }.joined(separator: ", ")
        paint()
    }

    func paint() {
        rule.backgroundColor = ChatPalette.separator
        glyph.strokeColor = ChatPalette.label2.resolvedColor(with: traitCollection).cgColor
        chevron.tintColor = action ? ChatPalette.tintText : HQPalette.cardNote
    }

    override var isHighlighted: Bool {
        didSet { alpha = PointerEffects.dim(isHighlighted, to: 0.45) }
    }
}
