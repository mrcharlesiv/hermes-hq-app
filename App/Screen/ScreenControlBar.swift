import UIKit

/// The bar under the picture (docs/spec/3x-screen.md §5.5, §5.6): who is in control, Take Control / Give Back, Fit, the
/// keyboard button and, while typing, the special keys, modifiers and Paste. System Liquid Glass buttons with nothing
/// painted behind them (the Watch Browser bar's pattern).
final class ScreenControlBar: UIView {
    struct Model: Equatable {
        var caption = ""
        /// "You were in control": drawn as a labelled orange badge.
        var held = false
        var take: String?
        var takeEnabled = true
        var give = false
        var force = false
        var busy: ScreenSession.Busy?
        var fit = false
        var keyboard = false
        var typing = false
        var mac = false
        var armed: Set<ScreenKeys.Modifier> = []
    }

    var onTake: (() -> Void)?
    var onGive: (() -> Void)?
    var onForce: (() -> Void)?
    var onFit: (() -> Void)?
    var onKeyboard: (() -> Void)?
    var onKey: ((ScreenKeys.Named) -> Void)?
    var onModifier: ((ScreenKeys.Modifier) -> Void)?
    var onPaste: (() -> Void)?

    var model = Model() { didSet { if model != oldValue { apply() } } }

    private let column = UIStackView()
    private let controlRow = UIStackView()
    private let who = UIStackView()
    private let buttons = UIStackView()
    private let caption = UILabel()
    private let badge = UIImageView(image: UIImage(systemName: "exclamationmark.circle.fill"))
    private let keysScroll = ScreenKeysScrollView()
    private let keysRow = UIStackView()
    private let modsScroll = ScreenKeysScrollView()
    private let modsRow = UIStackView()
    private lazy var take = action(ControlWords.take, "screen.take", prominent: true) { [weak self] in self?.onTake?() }
    private lazy var give = action(ControlWords.give, "screen.give", prominent: false) { [weak self] in self?.onGive?() }
    private lazy var force = action(ControlWords.endOther, "screen.force", prominent: false) { [weak self] in self?.onForce?() }
    private lazy var fit = key("Fit", spoken: "Fit screen", id: "screen.fit") { [weak self] in self?.onFit?() }
    private lazy var keyboard = icon("keyboard", ControlWords.showKeyboard, "screen.keyboard.toggle") { [weak self] in self?.onKeyboard?() }
    private lazy var paste = key("Paste", spoken: "Paste", id: "screen.paste") { [weak self] in self?.onPaste?() }
    private var specials: [UIButton] = []
    private var mods: [ScreenKeys.Modifier: UIButton] = [:]
    /// Sideways everything is one row. With the caption showing, the keys take exactly their own width and the caption
    /// the rest; while typing (no caption) the keys take what Give Back leaves, and scroll if they must.
    private lazy var keysWidth: NSLayoutConstraint = {
        let width = keysScroll.widthAnchor.constraint(equalTo: keysRow.widthAnchor)
        width.priority = UILayoutPriority(740)
        return width
    }()
    /// Beside the caption the buttons are only as wide as their words (the caption takes the rest of the row).
    private lazy var snugButtons = snug(buttons)
    private lazy var snugControls = snug(controlRow)
    private var narrow = true
    /// Each worded button's "at least 120 pt": off while the button is drawn as an icon (sideways while typing).
    private var wide: [UIButton: NSLayoutConstraint] = [:]
    private var compactGive = false

    private func snug(_ view: UIView) -> NSLayoutConstraint {
        let width = view.widthAnchor.constraint(equalToConstant: 0)
        width.priority = UILayoutPriority(300)
        return width
    }

    /// The end of a key row: whatever width the row is given beyond its keys goes here, never into a key.
    private func slack() -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        view.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
        let none = view.widthAnchor.constraint(equalToConstant: 0)
        none.priority = UILayoutPriority(2)
        none.isActive = true
        return view
    }

    private lazy var keysSlack = slack()
    private lazy var modsSlack = slack()

    override init(frame: CGRect) {
        super.init(frame: frame)
        column.axis = .vertical
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])

        caption.font = HQFont.preferred(.subheadline)
        caption.adjustsFontForContentSizeCategory = true
        caption.numberOfLines = 0
        caption.accessibilityIdentifier = "screen.caption"
        caption.setContentHuggingPriority(.defaultLow, for: .horizontal)
        caption.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        badge.tintColor = .systemOrange
        badge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.isHidden = true
        who.addArrangedSubview(badge)
        who.addArrangedSubview(caption)
        who.spacing = 6
        who.alignment = .center
        buttons.spacing = 8
        buttons.addArrangedSubview(give)
        buttons.addArrangedSubview(force)
        buttons.addArrangedSubview(take)
        controlRow.spacing = 10
        controlRow.alignment = .center
        controlRow.addArrangedSubview(who)
        controlRow.addArrangedSubview(buttons)
        // Which of the two gives way is said outright (two stacks side by side are otherwise a coin toss).
        who.setContentHuggingPriority(UILayoutPriority(249), for: .horizontal)
        who.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttons.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        buttons.setContentCompressionResistancePriority(.required, for: .horizontal)

        let named: [(String, String, ScreenKeys.Named, String)] = [
            ("Esc", "Escape", .escape, "screen.key.esc"), ("Tab", "Tab", .tab, "screen.key.tab"),
            ("←", "Left arrow", .left, "screen.key.left"), ("↑", "Up arrow", .up, "screen.key.up"),
            ("↓", "Down arrow", .down, "screen.key.down"), ("→", "Right arrow", .right, "screen.key.right"),
        ]
        specials = named.map { face, spoken, which, id in key(face, spoken: spoken, id: id) { [weak self] in self?.onKey?(which) } }
        let modifiers: [(String, String, ScreenKeys.Modifier, String)] = [
            ("Ctrl", "Control", .ctrl, "screen.mod.ctrl"), ("⌥", "Option", .alt, "screen.mod.alt"), ("⌘", "Command", .meta, "screen.mod.meta"),
        ]
        for (face, spoken, which, id) in modifiers {
            let button = key(face, spoken: spoken, id: id) { [weak self] in self?.onModifier?(which) }
            button.changesSelectionAsPrimaryAction = false
            mods[which] = button
        }
        for (scroll, row) in [(keysScroll, keysRow), (modsScroll, modsRow)] {
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            scroll.showsHorizontalScrollIndicator = false
            scroll.alwaysBounceHorizontal = false
            scroll.addSubview(row)
            scroll.lane = scroll.frameLayoutGuide.heightAnchor.constraint(equalTo: row.heightAnchor)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
                row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                scroll.lane,
            ])
            // The content is as wide as the row unless the keys need more (the slack takes the difference). Without
            // this the stack view's own text-width rule (priority 960: no worded key wider than its share of the row)
            // stretched a row holding Paste to about 700 pt, so a row with room to spare still scrolled.
            let fits = row.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
            fits.priority = UILayoutPriority(970)
            fits.isActive = true
            // The key rows keep a bar's size at the largest text sizes; the large content viewer shows the key.
            scroll.maximumContentSizeCategory = .accessibilityMedium
            scroll.addInteraction(UILargeContentViewerInteraction())
        }
        keysScroll.accessibilityIdentifier = "screen.keys"
        modsScroll.accessibilityIdentifier = "screen.mods"
        column.addArrangedSubview(keysScroll)
        column.addArrangedSubview(modsScroll)
        column.addArrangedSubview(controlRow)
        accessibilityIdentifier = "screen.bar"
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitVerticalSizeClass.self]) { (bar: ScreenControlBar, _) in
            bar.apply()
        }
        apply()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let now = bounds.width < 520
        if now != narrow {
            narrow = now
            apply()
        }
    }

    private func action(_ title: String, _ id: String, prominent: Bool, _ run: @escaping () -> Void) -> UIButton {
        var config = prominent ? UIButton.Configuration.hqProminentGlass() : UIButton.Configuration.hqGlass()
        config.title = title
        config.titleLineBreakMode = .byWordWrapping
        config.imagePadding = 6
        let button = UIButton(configuration: config)
        button.accessibilityIdentifier = id
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.addAction(UIAction { _ in run() }, for: .primaryActionTriggered)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let atLeast = button.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
        atLeast.isActive = true
        wide[button] = atLeast
        let target = button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44)
        target.isActive = true
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return button
    }

    /// A key is as wide as its face (44 pt at least) wherever its row puts it: rows give spare width to their slack.
    private func fixedWidth(_ button: UIButton) {
        button.setContentHuggingPriority(UILayoutPriority(999), for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func key(_ face: String, spoken: String, id: String, _ run: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.hqGlass()
        config.title = face
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        let button = UIButton(configuration: config)
        button.accessibilityLabel = spoken
        button.accessibilityIdentifier = id
        button.showsLargeContentViewer = true
        button.largeContentTitle = spoken
        button.addAction(UIAction { _ in run() }, for: .primaryActionTriggered)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        fixedWidth(button)
        return button
    }

    private func icon(_ symbol: String, _ label: String, _ id: String, _ run: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.hqGlass()
        config.image = UIImage(systemName: symbol)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
        let button = UIButton(configuration: config)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = id
        button.showsLargeContentViewer = true
        button.largeContentTitle = label
        button.addAction(UIAction { _ in run() }, for: .primaryActionTriggered)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        fixedWidth(button)
        return button
    }

    private func setRow(_ row: UIStackView, _ views: [UIView]) {
        guard row.arrangedSubviews != views else { return }
        for view in row.arrangedSubviews where !views.contains(view) {
            row.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, view) in views.enumerated() { row.insertArrangedSubview(view, at: index) }
    }

    private func apply() {
        caption.text = model.caption
        caption.textColor = model.held ? .systemOrange : .label
        badge.isHidden = !model.held
        let busy = model.busy
        configure(take, title: model.take ?? ControlWords.take, shown: model.take != nil, spinning: busy == .take,
                  enabled: model.takeEnabled && busy == nil)
        configure(give, title: ControlWords.give, shown: model.give, spinning: busy == .give, enabled: busy == nil)
        configure(force, title: ControlWords.endOther, shown: model.force, spinning: busy == .force, enabled: busy == nil)

        // At accessibility sizes the caption sits above full-width buttons; so it does on a narrow screen when two
        // buttons show (they would squeeze the caption into a column of letters).
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let short = traitCollection.verticalSizeClass == .compact
        let shown = [model.take != nil, model.give, model.force].filter { $0 }.count
        let stacked = large || (narrow && shown > 1)
        controlRow.axis = stacked ? .vertical : .horizontal
        controlRow.alignment = stacked ? .fill : .center
        buttons.axis = large ? .vertical : .horizontal
        buttons.distribution = stacked && !large ? .fillEqually : .fill
        // Side by side, the caption and the buttons are one line each: a stack view splits a row in half between
        // texts that may wrap, whatever their sizes. Stacked (large text, or two buttons on a narrow screen) they wrap.
        caption.numberOfLines = stacked ? 0 : 1
        caption.adjustsFontSizeToFitWidth = !stacked
        caption.minimumScaleFactor = 0.8
        for button in [take, give, force] {
            var config = button.configuration
            config?.titleLineBreakMode = large ? .byWordWrapping : .byTruncatingTail
            button.configuration = config
        }

        var config = keyboard.configuration
        config?.image = UIImage(systemName: model.typing ? "keyboard.chevron.compact.down" : "keyboard")
        keyboard.configuration = config
        keyboard.accessibilityLabel = model.typing ? ControlWords.hideKeyboard : ControlWords.showKeyboard
        keyboard.largeContentTitle = keyboard.accessibilityLabel
        for (which, button) in mods {
            button.isSelected = model.armed.contains(which)
            if model.armed.contains(which) { button.accessibilityTraits.insert(.selected) } else { button.accessibilityTraits.remove(.selected) }
        }

        var first: [UIView] = []
        if model.keyboard { first.append(keyboard) }
        if model.fit { first.append(fit) }
        var second: [UIView] = []
        if model.typing && model.keyboard {
            first += specials
            second = [mods[.ctrl]].compactMap { $0 }
            if model.mac { second += [mods[.alt], mods[.meta]].compactMap { $0 } }
            second.append(paste)
        }
        // Sideways: one row (the keys scroll if they must; while typing the caption gives them its room).
        // Portrait: keys, then modifiers and Paste, then the caption and buttons.
        if short {
            first += second
            second = []
        }
        setRow(keysRow, first.isEmpty ? [] : first + [keysSlack])
        setRow(modsRow, second.isEmpty ? [] : second + [modsSlack])
        keysScroll.isHidden = first.isEmpty
        modsScroll.isHidden = second.isEmpty
        let oneRow = short && !large
        let keysOnly = oneRow && model.typing && model.keyboard
        // Sideways with the keyboard up the row belongs to the keys (review: Paste was drawn cut in half under the
        // worded Give Back). Give Back becomes a 44 pt glass icon with the same name for VoiceOver and the large
        // content viewer, and the keys sit a little closer; a row that still overflows fades at its far edge.
        compactGive = keysOnly
        wide[give]?.isActive = !keysOnly
        var giveConfig = give.configuration
        giveConfig?.title = keysOnly ? nil : ControlWords.give
        giveConfig?.image = keysOnly ? (UIImage(systemName: "hand.raised.slash") ?? UIImage(systemName: "arrow.uturn.backward")) : nil
        giveConfig?.contentInsets = keysOnly ? NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10) : Self.wordedInsets
        give.configuration = giveConfig
        give.accessibilityLabel = ControlWords.give
        give.showsLargeContentViewer = keysOnly
        give.largeContentTitle = ControlWords.give
        let inset: CGFloat = keysOnly ? 8 : 10
        for button in specials + Array(mods.values) + [paste, fit] where button.configuration?.contentInsets.leading != inset {
            button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: inset, bottom: 6, trailing: inset)
        }
        column.axis = oneRow ? .horizontal : .vertical
        who.isHidden = keysOnly
        keysWidth.isActive = oneRow && !keysOnly
        keysScroll.setContentHuggingPriority(oneRow && !keysOnly ? .defaultHigh : UILayoutPriority(200), for: .horizontal)
        controlRow.setContentHuggingPriority(keysOnly ? .defaultHigh : UILayoutPriority(249), for: .horizontal)
        snugButtons.isActive = !stacked
        snugControls.isActive = keysOnly
    }

    /// The system's own insets for a worded glass button (read once from a fresh configuration).
    private static let wordedInsets = UIButton.Configuration.glass().contentInsets   // glass-ok: only its insets

    private func configure(_ button: UIButton, title: String, shown: Bool, spinning: Bool, enabled: Bool) {
        button.isHidden = !shown
        var config = button.configuration
        config?.title = title
        config?.showsActivityIndicator = spinning
        button.configuration = config
        button.isEnabled = enabled
    }
}

/// A row of keys that scrolls sideways when it must. DECISION (review finding 4): the reviewer suggested a fade mask
/// at the far edge; a mask on an ancestor of system glass buttons makes UIKit draw them off screen and can flatten the
/// glass, so the hint is the system's own instead: the scroll indicator shows while the row overflows and flashes the
/// moment it starts to.
final class ScreenKeysScrollView: UIScrollView {
    private(set) var overflows = false
    /// The row's height plus, while it overflows, the indicator's lane under the keys (owner 2026-10-29: the bar sat
    /// over them).
    var lane = NSLayoutConstraint()

    override func layoutSubviews() {
        super.layoutSubviews()
        let now = contentSize.width - bounds.width > 1 && bounds.width > 0
        guard now != overflows else { return }
        overflows = now
        lane.constant = now ? ScrollBarLane.height : 0
        showsHorizontalScrollIndicator = now
        if now { flashScrollIndicators() }
    }
}

/// The lines under the top bar (§5.9): why control is the way it is, and the error line with Dismiss.
final class ScreenNotesView: UIView {
    struct Line: Equatable {
        var text: String
        var warning = false
        var id: String
    }

    struct Model: Equatable {
        var error: String?
        var lines: [Line] = []
        /// The Mac's input is not ready: a row that opens the control-only setup card.
        var enableControl = false
    }

    var onDismissError: (() -> Void)?
    var onEnableControl: (() -> Void)?
    var model = Model() { didSet { if model != oldValue { apply(announce: model.error != oldValue.error) } } }

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var cap: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = HQPalette.plainPage
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        addSubview(scroll)
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        let fits = scroll.heightAnchor.constraint(equalTo: stack.heightAnchor)
        fits.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            fits,
        ])
        accessibilityIdentifier = "screen.notes"
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The notes never take more than this much of the screen: the picture always keeps room.
    func setHeightCap(_ points: CGFloat) {
        cap?.isActive = false
        cap = scroll.heightAnchor.constraint(lessThanOrEqualToConstant: max(60, points))
        cap?.isActive = true
    }

    private func row(_ text: String, color: UIColor, symbol: String?, id: String, trailing: UIView? = nil) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = HQFont.preferred(.footnote)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textColor = color
        label.accessibilityIdentifier = id
        // A line is never cut to fit: when the lines outgrow their share of the screen, they scroll.
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        var views: [UIView] = []
        if let symbol {
            let image = UIImageView(image: UIImage(systemName: symbol))
            image.tintColor = .systemOrange
            image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
            image.setContentHuggingPriority(.required, for: .horizontal)
            image.setContentCompressionResistancePriority(.required, for: .horizontal)
            image.isAccessibilityElement = false
            views.append(image)
        }
        views.append(label)
        if let trailing { views.append(trailing) }
        let line = UIStackView(arrangedSubviews: views)
        line.spacing = 8
        line.alignment = .firstBaseline
        line.isLayoutMarginsRelativeArrangement = true
        line.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0)
        return line
    }

    private func apply(announce: Bool) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let error = model.error, !error.isEmpty {
            var config = UIButton.Configuration.plain()
            config.title = "Dismiss"
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 0)
            let dismiss = UIButton(configuration: config)
            dismiss.accessibilityIdentifier = "screen.error.dismiss"
            // [a11y] A full 44 pt to tap, as the Enable row below it.
            dismiss.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            dismiss.setContentHuggingPriority(.required, for: .horizontal)
            dismiss.setContentCompressionResistancePriority(.required, for: .horizontal)
            dismiss.addAction(UIAction { [weak self] _ in self?.onDismissError?() }, for: .primaryActionTriggered)
            stack.addArrangedSubview(row(error, color: .systemRed, symbol: nil, id: "screen.error", trailing: dismiss))
            if announce { HQAnnounce.say(error) }
        }
        for line in model.lines {
            stack.addArrangedSubview(row(line.text, color: HQPalette.label2, symbol: line.warning ? "exclamationmark.triangle.fill" : nil, id: line.id))
        }
        if model.enableControl {
            var config = UIButton.Configuration.plain()
            config.title = "Enable Screen Control"
            config.image = UIImage(systemName: "chevron.forward")
            config.imagePlacement = .trailing
            config.imagePadding = 6
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .footnote)
            config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var out = incoming
                out.font = HQFont.preferred(.footnote)
                return out
            }
            let button = UIButton(configuration: config)
            button.contentHorizontalAlignment = .leading
            button.accessibilityIdentifier = "screen.enable-control"
            button.addAction(UIAction { [weak self] _ in self?.onEnableControl?() }, for: .primaryActionTriggered)
            stack.addArrangedSubview(button)
        }
        isHidden = stack.arrangedSubviews.isEmpty
    }
}
