// [mac-popups] Owner 2026-10-31: "the pop-ups, like clicking the hamburger next to the chat input, need a lot of work."
// On the Mac the composer's pick-lists (☰ Commands, Models) opened as iPhone form sheets: a window-tall card with a bar
// title, Done, an inset-grouped table of 64 pt rows and a search bar under the bar. A Mac opens a short list that
// belongs to a button as a pop-over hung off that button: as wide as its rows need, as tall as its rows (up to a cap),
// a search field at the top with the caret already in it, compact one-line rows, small grey section names, the row
// under the pointer or picked with ↑/↓ marked in the accent, Return picks, Esc or a click outside closes.
//
// This is that panel. It knows nothing about commands or models: a driver (MacMenusPanels.swift) gives it sections of
// rows, or a loading, empty or failed state, and answers its picks, stars and searches. Both looks: glass in the iOS
// look (owner: floating things on glass) with the rows on it, the raised solid surface with the stronger line in the
// Desktop Look (the look is flat and outlined). Open Quickly (MacOpenQuickly) is its sibling, centred on the window.

#if targetEnvironment(macCatalyst)
import UIKit

@MainActor final class MacPickPanel: UIViewController, UITableViewDataSource, UITableViewDelegate {
    struct Row: Hashable {
        /// Unique in the whole list (a row in Favorites and in its own section share it: the mark follows the section).
        var key: String
        var title: String
        /// Grey, after the title on the same line; cut short at the panel's edge (the whole of it is the row's tool tip).
        var detail: String = ""
        var checked = false
        /// nil: no star. Starred rows show a filled star always; the others show an outline on the marked row only.
        var starred: Bool?
        var enabled = true
        var identifier: String
        var starIdentifier: String = ""
        var accessibilityLabel: String
    }

    struct Section: Hashable {
        var title: String
        var rows: [Row]
        /// [model-fold] A section whose heading folds it (Models' providers, tester 2026-11-09, as on the
        /// iPhone): folded, the driver gives it no rows and the heading shows how many it holds.
        var fold: Fold? = nil
    }

    struct Fold: Hashable {
        var key: String
        var count: Int
        var folded: Bool
    }

    enum Content {
        case loading
        case rows([Section])
        /// A state with no rows: a title, a line under it, and push buttons (Try Again, Show Details, Check Again).
        case message(symbol: String?, title: String, text: String?, actions: [UIAction])
    }

    // The driver's hooks.
    var onQuery: ((String) -> Void)?
    /// A click or Return on an enabled row. The panel has closed by the time it runs.
    var onPick: ((Row) -> Void)?
    var onStar: ((Row) -> Void)?
    /// [model-fold] A foldable heading's click (its `Fold.key`), and its right click's Collapse All (true) / Expand All.
    var onFold: ((String) -> Void)?
    var onFoldAll: ((Bool) -> Void)?
    /// The panel closed without a pick (Esc, a click outside). Runs after it is gone.
    var onCancel: (() -> Void)?
    /// Keeps the driver alive as long as the panel is up.
    var driver: AnyObject?

    private let placeholder: String
    private weak var anchor: UIView?
    /// What the panel stays clear of, above or below (the whole composer); nil = the anchor alone.
    private weak var clearOf: UIView?
    private let width: CGFloat
    private let showsChecks: Bool
    private let panel = UIView()
    private let glassBack = UIVisualEffectView()
    private let fieldBox = UIView()
    let field = UITextField()
    private let note = UILabel()
    private let rule = UIView()
    /// Grouped, not plain: a plain table's section names float over the rows when it scrolls (a star that grows
    /// Favorites scrolls it to hold the row in place).
    private let table = UITableView(frame: .zero, style: .grouped)
    private let stateView = UIStackView()
    private var accessory: UIButton?

    private var content: Content = .loading
    private var sections: [Section] = []
    /// The marked row (↑/↓, the pointer); nil until either moves it or a search marks its first result.
    private var marked: IndexPath?
    private var picked = false
    /// [mac-feel] Fading out after Esc or a click outside (`hqHidePanel`).
    private var closing = false
    /// [mac-feel] The fade-in played (once: not again when a sheet over the panel goes, Show Details).
    private var fadedIn = false

    private static weak var shown: MacPickPanel?
    static var isShown: Bool { shown != nil }

    /// `anchor`: the button it hangs off (the panel opens above it when there's more room above, as at the composer).
    /// `clearOf`: a larger view around the anchor that the panel must not cover (the composer the ☰ sits in).
    init(placeholder: String, anchor: UIView, clearOf: UIView? = nil, width: CGFloat = 420, showsChecks: Bool = false,
         identifier: String) {
        self.placeholder = placeholder
        self.anchor = anchor
        self.clearOf = clearOf
        self.width = width
        self.showsChecks = showsChecks
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        panel.accessibilityIdentifier = identifier
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Presents over `host` (the top of its stack). A panel already up takes the caret back instead (a second ⌘ press).
    static func present(_ panel: MacPickPanel, from host: UIViewController) -> Bool {
        if let shown, shown.presentingViewController != nil, !shown.isBeingDismissed {
            if shown.closing {
                shown.dismiss(animated: false)   // [mac-feel] fading out after Esc: gone now, the new panel takes its place
            } else {
                shown.field.becomeFirstResponder()
                panel.driver = nil   // the driver and its panel hold each other until the panel goes
                return false
            }
        }
        shown = panel
        host.hqShowPanel(panel)
        return true
    }

    /// A small button at the field's trailing end (Models' Refresh).
    func setAccessory(symbol: String, label: String, identifier: String, action: @escaping () -> Void) {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: HQFont.preferred(.subheadline)))
        config.contentInsets = .zero
        button.configuration = config
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        button.addInteraction(UIToolTipInteraction(defaultToolTip: label))
        accessory = button
        if isViewLoaded { panel.addSubview(button); recolor(); view.setNeedsLayout() }
    }

    var accessoryEnabled: Bool {
        get { accessory?.isEnabled ?? false }
        set { accessory?.isEnabled = newValue }
    }

    /// One or two lines of footnote under the field (Models: what a pick changes, offline).
    func setNote(_ text: String?) {
        note.text = text
        note.isHidden = text?.isEmpty ?? true
        if isViewLoaded { view.setNeedsLayout() }
    }

    var query: String { field.text ?? "" }

    func setQuery(_ text: String) { field.text = text }

    // MARK: View

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let outside = UITapGestureRecognizer(target: self, action: #selector(tappedOutside(_:)))
        outside.cancelsTouchesInView = false
        view.addGestureRecognizer(outside)

        panel.layer.cornerCurve = .continuous
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowRadius = 18
        panel.layer.shadowOffset = CGSize(width: 0, height: 8)
        panel.accessibilityViewIsModal = true
        view.addSubview(panel)
        glassBack.isUserInteractionEnabled = false
        glassBack.clipsToBounds = true
        DesktopLayout.keepOwnLook(glassBack)   // the Desktop Look's surface is `panel`'s own fill (`recolor`)
        panel.addSubview(glassBack)

        fieldBox.layer.cornerCurve = .continuous
        panel.addSubview(fieldBox)
        let glass = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        glass.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: HQFont.preferred(.subheadline))
        glass.tag = 1
        fieldBox.addSubview(glass)
        field.font = HQFont.preferred(.body)
        // [mac] Mac polish #69: the hint in the look's label 2, as the bars' search fields have it
        // (`DesktopSearch.fitPlaceholder`); the system's placeholder grey read at about 2:1.
        field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: HQPalette.label2])
        field.accessibilityLabel = placeholder
        field.accessibilityIdentifier = "sheet.search"
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .go
        field.clearButtonMode = .whileEditing
        field.borderStyle = .none
        field.addAction(UIAction { [weak self] _ in self?.typed() }, for: .editingChanged)
        field.addAction(UIAction { [weak self] _ in self?.pickMarked() }, for: .primaryActionTriggered)
        field.addAction(UIAction { [weak self] _ in self?.ring() }, for: .editingDidBegin)
        field.addAction(UIAction { [weak self] _ in self?.ring() }, for: .editingDidEnd)
        fieldBox.addSubview(field)
        if let accessory { panel.addSubview(accessory) }

        note.font = HQFont.preferred(.footnote)
        note.numberOfLines = 0
        note.accessibilityIdentifier = "models.scope"
        panel.addSubview(note)
        panel.addSubview(rule)

        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.sectionHeaderTopPadding = 0
        table.sectionFooterHeight = 0
        table.estimatedSectionFooterHeight = 0
        table.tableHeaderView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNonzeroMagnitude))
        table.tableFooterView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNonzeroMagnitude))
        table.estimatedRowHeight = Self.rowHeight
        table.rowHeight = Self.rowHeight
        table.showsHorizontalScrollIndicator = false
        table.register(MacPickRowCell.self, forCellReuseIdentifier: MacPickRowCell.reuse)
        table.register(MacPickHeader.self, forHeaderFooterViewReuseIdentifier: MacPickHeader.reuse)
        table.register(MenusSkeletonCell.self, forCellReuseIdentifier: MenusSkeletonCell.reuse)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        table.addGestureRecognizer(hover)
        panel.addSubview(table)

        stateView.axis = .vertical
        stateView.alignment = .center
        stateView.spacing = 6
        stateView.isHidden = true
        panel.addSubview(stateView)

        recolor()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (panel: MacPickPanel, _) in
            panel.recolor()
            panel.table.reloadData()
        }
        apply()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if fieldBox.isHidden { becomeFirstResponder() } else { field.becomeFirstResponder() }
        if !fadedIn { fadedIn = true; hqPanelAppeared() }   // [mac-feel]
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil else { return }   // not for a sheet over it (Show Details)
        if Self.shown === self { Self.shown = nil }
        driver = nil   // the driver and its panel hold each other until the panel goes
    }

    override var canBecomeFirstResponder: Bool { true }

    // Metrics, in the app's points (the Mac draws them at 77 %).
    static let pad: CGFloat = 8
    /// One row: 38 pt with the Mac's body text (≈ 29 pt on screen, a macOS table's large row).
    static var rowHeight: CGFloat { (HQFont.preferred(.body).lineHeight + 16).rounded() }
    static var headerHeight: CGFloat { (HQFont.preferred(.footnote).lineHeight + 14).rounded() }
    private static var fieldHeight: CGFloat { (HQFont.preferred(.body).lineHeight + 14).rounded() }
    /// The iOS look's corners: the field's 8 pt box 8 pt inside them, concentric.
    private static let glassRadius: CGFloat = 16

    private var isDesktop: Bool { Theme.isDesktop }

    private func recolor() {
        let desktop = isDesktop
        let dark = traitCollection.userInterfaceStyle == .dark
        if desktop { if glassBack.effect != nil { glassBack.effect = nil } } else if !(glassBack.effect is UIGlassEffect) {
            glassBack.effect = UIGlassEffect(style: .regular)
        }
        glassBack.isHidden = desktop
        let radius = desktop ? HQShape.desktopRadius(.sheet) : Self.glassRadius
        glassBack.cornerConfiguration = .corners(radius: .fixed(radius))
        // [Mac UI check 2026-11-13] L2, L9: the glass alone let the chat's words show through as ghost text.
        panel.backgroundColor = desktop ? ChatPalette.elevated : ChatPalette.popupVeil
        panel.layer.cornerRadius = radius
        panel.layer.borderWidth = desktop ? 1 : 0
        panel.layer.borderColor = ChatPalette.strokePrimary.resolvedColor(with: traitCollection).cgColor
        // Under see-through glass a drawn shadow would darken it; the glass has its own.
        panel.layer.shadowOpacity = desktop ? (dark ? 0.55 : 0.22) : 0
        fieldBox.backgroundColor = desktop ? ChatPalette.editor : Self.well
        fieldBox.layer.cornerRadius = desktop ? DesktopRows.radius : 8
        (fieldBox.viewWithTag(1) as? UIImageView)?.tintColor = HQPalette.label2
        field.textColor = HQPalette.label
        field.tintColor = ChatPalette.caret
        note.textColor = HQPalette.label2
        rule.backgroundColor = desktop ? ChatPalette.strokeSecondary : HQPalette.separator
        accessory?.tintColor = HQPalette.label2
        ring()
    }

    /// The field's well on the glass: a shade, not a solid grey slab (Open Quickly's).
    private static let well = UIColor { traits in
        UIColor.label.resolvedColor(with: traits).withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.1 : 0.05)
    }

    /// The focus ring: the accent while the field has the caret, the look's line otherwise.
    private func ring() {
        let on = field.isFirstResponder
        let colour = on ? HQPalette.tint : (isDesktop ? ChatPalette.strokeSecondary : HQPalette.paneLine)
        // [Mac UI check 2026-11-13] L2: on the iOS look's glass card a solid 2 pt blue ring read hard; there it is the
        // accent at 1.5 pt and 60 %. The Desktop Look keeps its flat 2 pt ring.
        let soft = on && !isDesktop
        fieldBox.layer.borderColor = colour.resolvedColor(with: traitCollection).withAlphaComponent(soft ? 0.6 : 1).cgColor
        fieldBox.layer.borderWidth = on ? (soft ? 1.5 : 2) : 1
    }

    // MARK: Layout

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPanel()
        if centreMarkOnLayout, let marked, view.window != nil {
            centreMarkOnLayout = false
            table.layoutIfNeeded()
            table.scrollToRow(at: marked, at: .middle, animated: false)
        }
    }

    /// The panel's height for what it shows, and where it sits: above the anchor with more room there (the composer's
    /// buttons), else under it; its leading edge at the anchor's, kept inside the window.
    private func layoutPanel() {
        let bounds = view.bounds
        guard bounds.width > 0 else { return }
        let pad = Self.pad
        let w = min(width, bounds.width - 2 * pad)
        var y = pad
        // Field (and the accessory beside it); none while there is nothing to search.
        let fieldH = fieldBox.isHidden ? -pad : Self.fieldHeight
        var fieldW = w - 2 * pad
        if let accessory {
            let side = fieldH
            fieldW -= side + 4
            accessory.frame = CGRect(x: w - pad - side, y: y, width: side, height: fieldH)
        }
        fieldBox.frame = CGRect(x: pad, y: y, width: fieldW, height: fieldH)
        if let glass = fieldBox.viewWithTag(1) {
            let size = glass.intrinsicContentSize
            glass.frame = CGRect(x: 9, y: ((fieldH - size.height) / 2).rounded(), width: size.width, height: size.height)
            field.frame = CGRect(x: glass.frame.maxX + 6, y: 0, width: fieldW - glass.frame.maxX - 6 - 4, height: fieldH)
        }
        y += fieldH
        if !note.isHidden {
            let textX = 6 + MacPickRowCell.textInset
            let size = note.sizeThatFits(CGSize(width: w - textX - pad, height: .greatestFiniteMagnitude))
            y += 6
            note.frame = CGRect(x: textX, y: y, width: w - textX - pad, height: ceil(size.height))
            y += ceil(size.height)
        }
        y += pad
        rule.frame = CGRect(x: 0, y: y, width: w, height: 1 / max(1, traitCollection.displayScale))
        let listTop = y

        // Room: the space on the anchor's roomier side, less a margin.
        let anchorFrame = anchor.flatMap { $0.window != nil ? $0.convert($0.bounds, to: view) : nil }
            ?? CGRect(x: pad * 3, y: bounds.maxY - 80, width: 40, height: 40)
        // [mac-audit] Owner 2026-11-02 (Mac audit #3): in the iOS look the ☰ sits on the composer's bottom row, so a panel
        // hung 6 pt above the ☰ covered the field's first line (the typed text, blurred bubbles through it). The panel
        // clears the whole composer instead, in both looks; its leading edge still follows the ☰.
        let edges = clearOf.flatMap { $0.window != nil ? anchorFrame.union($0.convert($0.bounds, to: view)) : nil } ?? anchorFrame
        let gap: CGFloat = 6
        let roomAbove = edges.minY - gap - view.safeAreaInsets.top - pad * 2
        let roomBelow = bounds.maxY - edges.maxY - gap - pad * 2
        let above = roomAbove >= roomBelow
        let room = max(160, above ? roomAbove : roomBelow)
        let maxList = min(Self.maxListHeight, room - listTop)

        var listH: CGFloat
        switch content {
        case .message:
            stateView.isHidden = false
            table.isHidden = true
            let fit = stateView.systemLayoutSizeFitting(CGSize(width: w - 6 * pad, height: UIView.layoutFittingCompressedSize.height),
                                                       withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
            listH = min(maxList, ceil(fit.height) + 2 * 22)
            stateView.frame = CGRect(x: 3 * pad, y: listTop + 22, width: w - 6 * pad, height: listH - 44)
        case .loading:
            stateView.isHidden = true
            table.isHidden = false
            listH = min(maxList, 5 * Self.rowHeight + 10)
        case .rows:
            stateView.isHidden = true
            table.isHidden = false
            if sections.isEmpty {
                listH = min(maxList, 72)
            } else {
                var total: CGFloat = 4 + 6   // the gap over the first row and the foot under the last
                for section in sections { total += (section.title.isEmpty ? 0 : Self.headerHeight) + CGFloat(section.rows.count) * Self.rowHeight }
                listH = min(maxList, total)
            }
        }
        // While it is up the panel never shrinks: a search that finds fewer rows leaves the field where it was (the
        // panel hangs above the composer, so a shorter one would move the field under the caret at every key).
        if case .rows = content {
            listH = max(listH, min(maxList, tallestList))
            tallestList = listH
        }
        let foot: CGFloat = 6
        table.frame = CGRect(x: 6, y: listTop + 4, width: w - 12, height: max(0, listH - 4 - foot))
        table.isScrollEnabled = table.contentSize.height > table.bounds.height + 1 || listH >= maxList
        let h = listTop + listH
        // [Mac UI check 2026-11-13] V22: a button in the window's trailing half (the box's model pill) has the panel's
        // trailing edge at its own, so the panel hangs off it rather than off the far side of the box.
        var x = anchorFrame.midX > bounds.midX ? anchorFrame.maxX + pad - w : anchorFrame.minX - pad
        x = min(max(pad, x), bounds.width - pad - w)
        let top = above ? edges.minY - gap - h : edges.maxY + gap
        panel.frame = CGRect(x: x, y: max(view.safeAreaInsets.top + pad, top), width: w, height: h)
        glassBack.frame = panel.bounds
        panel.layer.shadowPath = UIBezierPath(roundedRect: panel.bounds, cornerRadius: panel.layer.cornerRadius).cgPath
        emptyNote?.frame = table.bounds
    }

    /// The list's tallest: 12 rows or so, then it scrolls.
    private static var maxListHeight: CGFloat { (rowHeight * 12.5).rounded() }

    // MARK: Content

    /// Shows what the driver has. The marked row stays on the same row (by key and section) when it is still there.
    func show(_ content: Content, markFirst: Bool = false, holding key: (section: String, key: String)? = nil) {
        let before: CGFloat? = key.flatMap { path(of: $0.key, in: $0.section) }.map { table.rectForRow(at: $0).minY - table.contentOffset.y }
        let markedKey: (String, String)? = marked.flatMap { path in row(at: path).map { (sections[path.section].title, $0.key) } }
        self.content = content
        if case .rows(let s) = content { sections = s } else { sections = [] }
        marked = nil
        if let markedKey, let path = path(of: markedKey.1, in: markedKey.0) { marked = path }
        if markFirst { marked = firstEnabled() }
        guard isViewLoaded else { return }
        apply()
        if let key, let before, let path = path(of: key.key, in: key.section) {
            table.layoutIfNeeded()
            let after = table.rectForRow(at: path).minY - table.contentOffset.y
            let maxOffset = max(0, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
            table.contentOffset.y = min(maxOffset, max(0, table.contentOffset.y + after - before))
        }
    }

    /// [mac-ten] Owner 2026-11-11 ("weird UI issues"): the next rows the driver shows size the panel afresh. Collapse
    /// All left Models as a tall panel with five headings at its top and blank glass under them, because a panel never
    /// shrinks while it is up (a search must not move the field under the caret). Collapse All and Expand All come
    /// from a menu, not from a key or a click on a row that would move, so the panel fits what it then shows.
    func fitNextRows() { tallestList = 0 }

    /// Marks a row and brings it into view (Models: the current model as the panel opens).
    func mark(key: String, scroll: Bool = true) {
        // The last match: a model in Favorites is also in its provider's section, which the mark prefers.
        let matches = sections.indices.compactMap { s in sections[s].rows.firstIndex { $0.key == key }.map { IndexPath(row: $0, section: s) } }
        guard let path = matches.last else { return }
        marked = path
        centreMarkOnLayout = scroll
        guard isViewLoaded else { return }
        table.reloadData()
        view.setNeedsLayout()
    }

    /// The next layout puts the marked row in the middle of the list (the panel's size is known only then).
    private var centreMarkOnLayout = false

    private var emptyNote: UILabel?
    /// The list's tallest height so far (see `layoutPanel`).
    private var tallestList: CGFloat = 0

    private func apply() {
        for view in stateView.arrangedSubviews { view.removeFromSuperview() }
        emptyNote?.removeFromSuperview()
        emptyNote = nil
        switch content {
        case .loading:
            table.accessibilityLabel = "Loading"
        case .rows:
            table.accessibilityLabel = nil
            if sections.isEmpty {
                let label = UILabel()
                label.text = query.isEmpty ? "Nothing to show" : "No Results for \u{201C}\(query)\u{201D}"
                label.font = HQFont.preferred(.subheadline)
                label.textColor = HQPalette.label2
                label.textAlignment = .center
                label.accessibilityIdentifier = "panel.noResults"
                table.addSubview(label)
                emptyNote = label
            }
        case .message(let symbol, let title, let text, let actions):
            if let symbol {
                let image = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: HQFont.preferred(.title2))))
                image.tintColor = HQPalette.label2
                stateView.addArrangedSubview(image)
                stateView.setCustomSpacing(10, after: image)
            }
            let heading = UILabel()
            heading.text = title
            heading.font = HQFont.preferred(.headline)
            heading.textColor = HQPalette.label
            heading.textAlignment = .center
            heading.numberOfLines = 0
            stateView.addArrangedSubview(heading)
            if let text {
                let line = UILabel()
                line.text = text
                line.font = HQFont.preferred(.subheadline)
                line.textColor = HQPalette.label2
                line.textAlignment = .center
                line.numberOfLines = 0
                stateView.addArrangedSubview(line)
            }
            if !actions.isEmpty {
                let buttons = UIStackView(arrangedSubviews: actions.enumerated().map { index, action in
                    let button = UIButton(configuration: MacPush.configuration(index == 0 ? .prominent : .plain), primaryAction: action)
                    return button
                })
                buttons.axis = .horizontal
                buttons.spacing = 8
                if let last = stateView.arrangedSubviews.last { stateView.setCustomSpacing(14, after: last) }
                stateView.addArrangedSubview(buttons)
            }
        }
        // The search field goes while there is nothing to search (a failed or empty answer), as the sheet's did (#71).
        var searchable = true
        if case .message = content { searchable = !query.isEmpty }
        if searchable != !fieldBox.isHidden {
            fieldBox.isHidden = !searchable
            accessory?.isHidden = !searchable
            rule.isHidden = !searchable
            // Esc still closes it: with no field the panel itself takes the keys.
            if searchable { if view.window != nil { field.becomeFirstResponder() } } else { becomeFirstResponder() }
        }
        table.reloadData()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        if let marked { table.scrollToRow(at: marked, at: .none, animated: false) }
    }

    private func row(at path: IndexPath) -> Row? {
        guard path.section < sections.count, path.row < sections[path.section].rows.count else { return nil }
        return sections[path.section].rows[path.row]
    }

    private func path(of key: String, in section: String) -> IndexPath? {
        guard let s = sections.firstIndex(where: { $0.title == section }), let r = sections[s].rows.firstIndex(where: { $0.key == key }) else { return nil }
        return IndexPath(row: r, section: s)
    }

    private var flat: [IndexPath] {
        sections.indices.flatMap { s in sections[s].rows.indices.map { IndexPath(row: $0, section: s) } }
    }

    private func firstEnabled() -> IndexPath? { flat.first { row(at: $0)?.enabled == true } }

    private func typed() {
        onQuery?(query)
    }

    // MARK: Table

    func numberOfSections(in tableView: UITableView) -> Int {
        switch content { case .loading: 1; case .rows: sections.count; case .message: 0 }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if case .loading = content { return 5 }
        return sections[section].rows.count
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        guard case .rows = content, section < sections.count, !sections[section].title.isEmpty else { return .leastNonzeroMagnitude }
        return Self.headerHeight
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat { .leastNonzeroMagnitude }
    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? { nil }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard case .rows = content, section < sections.count, !sections[section].title.isEmpty else { return nil }
        let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: MacPickHeader.reuse) as? MacPickHeader
        let folds = sections.compactMap(\.fold)
        header?.configure(sections[section].title, indent: showsChecks ? MacPickRowCell.checkColumn : 0, fold: sections[section].fold,
                          canFoldAll: folds.contains { !$0.folded }, canOpenAll: folds.contains(where: \.folded))
        header?.onToggle = { [weak self] key in self?.onFold?(key) }
        header?.onAll = { [weak self] fold in self?.onFoldAll?(fold) }
        return header
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if case .loading = content {
            let cell = tableView.dequeueReusableCell(withIdentifier: MenusSkeletonCell.reuse, for: indexPath) as! MenusSkeletonCell
            cell.backgroundConfiguration = .clear()
            cell.configure(fraction: [0.45, 0.57, 0.69, 0.45, 0.57][indexPath.row % 5])
            return cell
        }
        let row = sections[indexPath.section].rows[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: MacPickRowCell.reuse, for: indexPath) as! MacPickRowCell
        cell.configure(row, marked: indexPath == marked, showsCheck: showsChecks)
        let title = sections[indexPath.section].title
        cell.onStar = { [weak self] in
            guard let self, let current = self.path(of: row.key, in: title).flatMap(self.row(at:)) else { return }
            self.onStar?(current)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        row(at: indexPath)?.enabled == true
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard case .rows = content else { return }
        setMark(indexPath)
        pickMarked()
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        guard case .rows = content else { return }
        switch recognizer.state {
        case .began, .changed:
            let path = table.indexPathForRow(at: recognizer.location(in: table))
            if let path, row(at: path)?.enabled == true, path != marked { setMark(path) }
        default: break
        }
    }

    private func setMark(_ path: IndexPath?) {
        let old = marked
        marked = path
        for p in [old, path].compactMap({ $0 }) {
            guard let cell = table.cellForRow(at: p) as? MacPickRowCell, let row = row(at: p) else { continue }
            cell.configure(row, marked: p == path, showsCheck: showsChecks)
        }
    }

    // MARK: Keys

    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(moveUp)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(moveDown)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close)),
        ]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }   // before the field's own caret moves
        // [favorite-commands] ⌘D stars or unstars the marked row, as Safari's Add Bookmark.
        if let marked, let row = row(at: marked), let starred = row.starred {
            let star = UIKeyCommand(title: ComposerDrawerModel.favoriteAction(favorited: starred).title, action: #selector(starMarked),
                                    input: "d", modifierFlags: .command)
            star.wantsPriorityOverSystemBehavior = true
            return commands + [star]
        }
        return commands
    }

    @objc private func starMarked() {
        guard let marked, let row = row(at: marked), row.starred != nil else { return }
        onStar?(row)
    }

    /// [favorite-commands] A right-click (Control-click) on a row: Add to Favorites / Remove from Favorites.
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard case .rows = content, let row = row(at: indexPath), let starred = row.starred else { return nil }
        let wording = ComposerDrawerModel.favoriteAction(favorited: starred)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let action = UIAction(title: wording.title, image: UIImage(systemName: wording.image)) { _ in
                guard let self, let current = self.row(at: indexPath), current.key == row.key else { return }
                self.onStar?(current)
            }
            action.accessibilityIdentifier = "panel.favorite.\(row.key)"
            return UIMenu(children: [action])
        }
    }

    @objc private func moveUp() { move(by: -1) }
    @objc private func moveDown() { move(by: 1) }

    /// ↓ from nothing marks the first row, ↑ the last; disabled rows are stepped over.
    func move(by step: Int) {
        let rows = flat.filter { row(at: $0)?.enabled == true }
        guard !rows.isEmpty else { return }
        let next: IndexPath
        if let marked, let at = rows.firstIndex(of: marked) {
            next = rows[max(0, min(rows.count - 1, at + step))]
        } else {
            next = step > 0 ? rows[0] : rows[rows.count - 1]
        }
        setMark(next)
        table.scrollToRow(at: next, at: .none, animated: false)
    }

    func pickMarked() {
        guard let marked, let row = row(at: marked), row.enabled, !picked else { return }
        picked = true
        let pick = onPick
        let keep = driver   // its pick runs after the panel has gone
        dismiss(animated: false) { pick?(row); _ = keep }   // [mac-feel] at once: the pick no longer waits for a fade-out
    }

    @objc func close() {
        guard !isBeingDismissed, !closing else { return }
        closing = true
        let cancel = picked ? nil : onCancel
        let keep = driver
        hqHidePanel { cancel?(); _ = keep }
    }

    @objc private func tappedOutside(_ recognizer: UITapGestureRecognizer) {
        if !panel.bounds.contains(recognizer.location(in: panel)) { close() }
    }

    #if DEBUG
    var debugPanelFrame: CGRect { panel.frame }
    var debugMarked: IndexPath? { marked }
    #endif
}

/// A pop-over row: [✓] title  detail ……… [★]. One line; the mark is a rounded box in the accent (the window's selection,
/// `MacSelection.accent`), the row's own colours readable on it.
final class MacPickRowCell: UITableViewCell {
    static let reuse = "mac.pick.row"
    /// Where row text starts inside the table (the mark's own inset + the text's).
    static let textInset: CGFloat = 10
    /// The check column of a list with checks (Models): every title starts after it, checked or not.
    static var checkColumn: CGFloat { (HQFont.preferred(.body).lineHeight + 2).rounded() }
    var onStar: (() -> Void)?

    private let check = UIImageView()
    private let title = UILabel()
    private let detail = UILabel()
    private let star = UIButton(type: .system)
    private let tip = UIToolTipInteraction()
    private var showsCheck = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        title.font = MacType.row
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultHigh + 1, for: .horizontal)
        detail.font = MacType.row
        detail.lineBreakMode = .byTruncatingTail
        detail.isAccessibilityElement = false
        check.contentMode = .center
        check.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(font: HQFont.preferred(.subheadline).pagesWeight(.semibold)))
        var config = UIButton.Configuration.plain()
        config.contentInsets = .zero
        star.configuration = config
        star.addAction(UIAction { [weak self] _ in self?.onStar?() }, for: .primaryActionTriggered)
        for v in [check, title, detail, star] as [UIView] { contentView.addSubview(v) }
        addInteraction(tip)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ row: MacPickPanel.Row, marked: Bool, showsCheck: Bool) {
        self.showsCheck = showsCheck
        var background = UIBackgroundConfiguration.clear()
        if marked {
            background.backgroundColor = MacSelection.accent
            background.cornerRadius = MacSelection.radius
        }
        backgroundConfiguration = background
        title.text = row.title
        title.textColor = row.enabled ? HQPalette.label : HQPalette.label3
        detail.text = row.detail
        detail.isHidden = row.detail.isEmpty
        detail.textColor = row.enabled ? HQPalette.label2 : HQPalette.label3
        check.isHidden = !(showsCheck && row.checked)
        check.tintColor = row.enabled ? HQPalette.label : HQPalette.label3
        let starred = row.starred ?? false
        star.isHidden = row.starred == nil || !(starred || marked)
        star.configuration?.image = UIImage(systemName: starred ? "star.fill" : "star",
                                            withConfiguration: UIImage.SymbolConfiguration(font: HQFont.preferred(.subheadline)))
        star.tintColor = starred ? ChatPalette.tint : HQPalette.label2
        star.accessibilityLabel = "Favorite \(row.title)"
        star.accessibilityTraits = starred ? [.button, .selected] : .button
        star.accessibilityIdentifier = row.starIdentifier
        star.toolTip = ComposerDrawerModel.favoriteAction(favorited: starred).title
        isAccessibilityElement = true
        accessibilityLabel = row.accessibilityLabel
        accessibilityValue = row.checked ? "Current" : nil
        accessibilityTraits = row.enabled ? (row.checked ? [.button, .selected] : .button) : [.button, .notEnabled]
        accessibilityIdentifier = row.identifier
        // The star stays its own element (VoiceOver's custom action on the row).
        accessibilityCustomActions = row.starred == nil ? nil : [UIAccessibilityCustomAction(name: ComposerDrawerModel.favoriteAction(favorited: starred).title) { [weak self] _ in
            self?.onStar?()
            return true
        }]
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = contentView.bounds
        var x = Self.textInset
        if showsCheck {
            let side = Self.checkColumn
            check.frame = CGRect(x: x - 2, y: (b.height - side) / 2, width: side, height: side)
            x += side
        }
        let starSide = b.height
        let trailing = b.width - (star.isHidden && accessibilityCustomActions == nil ? Self.textInset : starSide)
        star.frame = CGRect(x: b.width - starSide - 2, y: 0, width: starSide, height: b.height)
        let titleW = min(title.intrinsicContentSize.width, trailing - x)
        let lineH = ceil(title.font.lineHeight)
        let y = ((b.height - lineH) / 2).rounded()
        title.frame = CGRect(x: x, y: y, width: max(0, titleW), height: lineH)
        let detailX = title.frame.maxX + 10
        detail.frame = CGRect(x: detailX, y: y, width: max(0, trailing - detailX - 4), height: lineH)
        // The whole of a line that is cut short shows as the row's tool tip.
        let cut = (!detail.isHidden && detail.intrinsicContentSize.width > detail.frame.width + 0.5)
            || title.intrinsicContentSize.width > title.frame.width + 0.5
        tip.defaultToolTip = cut ? [title.text, detail.text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ") : nil
    }
}

/// A section's name: the Mac's small grey header (footnote semibold); the Desktop Look's tracked capitals.
final class MacPickHeader: UITableViewHeaderFooterView, UIContextMenuInteractionDelegate {
    static let reuse = "mac.pick.header"
    private let label = UILabel()
    /// [model-fold] A foldable heading: a click folds or opens it; a right click has Collapse All and Expand All.
    private var fold: MacPickPanel.Fold?
    private var canFoldAll = false
    private var canOpenAll = false
    var onToggle: ((String) -> Void)?
    var onAll: ((Bool) -> Void)?

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        backgroundConfiguration = .clear()
        contentView.addSubview(label)
        accessibilityTraits = .header
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var indent: CGFloat = 0

    /// `indent`: the check column's width, so the name lines up with the row titles under it (a Mac menu's way).
    func configure(_ title: String, indent: CGFloat, fold: MacPickPanel.Fold? = nil, canFoldAll: Bool = false, canOpenAll: Bool = false) {
        self.indent = indent
        self.fold = fold
        self.canFoldAll = canFoldAll
        self.canOpenAll = canOpenAll
        let words: NSMutableAttributedString
        let font: UIFont
        if Theme.isDesktop {
            let attributes = DesktopLayout.labelAttributes()
            words = NSMutableAttributedString(string: title.uppercased(), attributes: attributes)
            font = attributes[.font] as? UIFont ?? HQFont.preferred(.footnote)
        } else {
            font = HQFont.preferred(.footnote).pagesWeight(.semibold)
            words = NSMutableAttributedString(string: title, attributes: [.font: font, .foregroundColor: HQPalette.label2])
        }
        if let fold {
            // As the iPhone's heading: the count while folded, then the caret.
            if fold.folded { words.append(NSAttributedString(string: "  \(fold.count)", attributes: [.font: font, .foregroundColor: HQPalette.label3])) }
            let caret = UIImage(systemName: fold.folded ? "chevron.forward" : "chevron.down",
                                withConfiguration: UIImage.SymbolConfiguration(font: HQFont.system(ofSize: font.pointSize * 0.7, weight: .semibold)))
            if let caret {
                words.append(NSAttributedString(string: "  "))
                words.append(NSAttributedString(attachment: NSTextAttachment(image: caret.withTintColor(HQPalette.label3, renderingMode: .alwaysOriginal))))
            }
        }
        label.attributedText = words
        accessibilityLabel = title
        accessibilityIdentifier = fold.map { "models.provider.\($0.key)" }
        accessibilityValue = fold.map { $0.folded ? "Collapsed, \($0.count) model\($0.count == 1 ? "" : "s")" : "Expanded" }
        accessibilityTraits = fold == nil ? .header : [.header, .button]
        var actions: [UIAccessibilityCustomAction] = []
        if fold != nil, canFoldAll { actions.append(UIAccessibilityCustomAction(name: "Collapse All") { [weak self] _ in self?.onAll?(true); return true }) }
        if fold != nil, canOpenAll { actions.append(UIAccessibilityCustomAction(name: "Expand All") { [weak self] _ in self?.onAll?(false); return true }) }
        accessibilityCustomActions = actions
        setNeedsLayout()
    }

    @objc private func tapped() { if let fold { onToggle?(fold.key) } }

    override func accessibilityActivate() -> Bool {
        guard let fold else { return false }
        onToggle?(fold.key)
        return true
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard fold != nil, canFoldAll || canOpenAll else { return nil }
        let foldAll = canFoldAll, openAll = canOpenAll
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var items: [UIMenuElement] = []
            if foldAll { items.append(UIAction(title: "Collapse All", image: UIImage(systemName: "rectangle.compress.vertical")) { [weak self] _ in self?.onAll?(true) }) }
            if openAll { items.append(UIAction(title: "Expand All", image: UIImage(systemName: "rectangle.expand.vertical")) { [weak self] _ in self?.onAll?(false) }) }
            return UIMenu(children: items)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = label.intrinsicContentSize
        // Sits on the rows under it: more room above than below.
        let x = MacPickRowCell.textInset + indent
        label.frame = CGRect(x: x, y: contentView.bounds.height - size.height - 4, width: contentView.bounds.width - x - MacPickRowCell.textInset,
                             height: size.height)
    }
}
#endif
