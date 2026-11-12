import UIKit

/// [dashboard] The Dashboard's pages as a row of names under its header (owner 2026-11-03: "pages within the dashboards
/// page"): tap one to show it, hold one to Rename, Move or Delete it, ＋ for a new page. It scrolls sideways when the
/// names outgrow the width. [header-menus] A ⋯ after the ＋ opens the shown page's hold menu (owner 2026-11-03, menu review
/// "Actions you can only reach by long-press").
@MainActor
final class DashboardPagesBar: UIView {
    var onSelect: ((String) -> Void)?
    var onAdd: (() -> Void)?
    var menuFor: ((DashboardPage) -> UIMenu?)?

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var chips: [String: UIButton] = [:]
    /// The page whose name a held tile is over (nil: none).
    private var highlighted: String?
    /// [tiles-glass-pills] The pills in one glass container, as `hqPickGlassRow`: glass can't sample glass, so without
    /// it the ＋ lensed the shown page's tint into a smear along its edge. Spacing 0: the pills never melt together.
    private let glassRow: UIVisualEffectView = {
        let container = UIGlassContainerEffect()
        container.spacing = 0
        return UIVisualEffectView(effect: container)
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.clipsToBounds = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        glassRow.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(glassRow)
        glassRow.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassRow.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            glassRow.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            glassRow.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            glassRow.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            glassRow.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            stack.topAnchor.constraint(equalTo: glassRow.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glassRow.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glassRow.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: glassRow.contentView.trailingAnchor),
        ])
        accessibilityIdentifier = "dashboard.pages"
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The names, the shown one filled, and how many tiles each holds (for VoiceOver).
    func show(_ pages: [DashboardPage], current: String, counts: [String: Int]) {
        // Drawn afresh each time (a few buttons): the theme's colours and fonts come along.
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        chips = [:]
        for page in pages {
            let chip = makeChip(page, selected: page.id == current, count: counts[page.id] ?? 0)
            chips[page.id] = chip
            stack.addArrangedSubview(chip)
        }
        stack.addArrangedSubview(makeAdd())
        if let page = pages.first(where: { $0.id == current }), let menu = menuFor?(page) {
            stack.addArrangedSubview(makeMore(page, menu: menu))   // [header-menus]
        }
        layoutIfNeeded()
        if let shown = chips[current] { scroll.scrollRectToVisible(shown.frame.insetBy(dx: -24, dy: 0), animated: false) }
    }

    /// The page whose name is under `point` (a tile dragged onto it in Edit Tiles).
    func pageId(at point: CGPoint, in view: UIView) -> String? {
        chips.first { _, chip in chip.convert(chip.bounds.insetBy(dx: -4, dy: -8), to: view).contains(point) }?.key
    }

    /// The name a dragged tile is over, lit up (nil: none).
    func highlight(_ id: String?) {
        // A tick as a page's name lights under a held tile (once per name, not per move of the finger).
        if id != highlighted, id != nil { Haptics.play(.selection) }
        highlighted = id
        for (key, chip) in chips {
            let on = key == id
            HQMotion.animate(0.15) { chip.transform = on ? CGAffineTransform(scaleX: 1.12, y: 1.12) : .identity }
        }
    }

    // [tiles-glass-pills] Owner 2026-11-10: the page names didn't match the pills on Sessions and Tasks ("not liquid
    // glass, just a completely different design"). They are now drawn as `SessionPill` is: in the iOS look a 34 pt
    // Liquid Glass capsule, the shown page the tint's prominent glass with its words in the tint's ink; in the Desktop
    // Look a 28 pt flat piece with the look's square corners, the tint or the grey fill. Words medium either way.

    /// The pill's height, as `SessionPill`'s (UI Scale, not Compact).
    private static var pillHeight: CGFloat { Theme.isDesktop ? HQFont.scaled(28) : HQFont.scaled(34) }

    /// In the dark the glass lifts the tint, and white words on the shown page read 3.3:1; a third darker, 7.5:1 (as
    /// `hqPickGlass(prominent:)`).
    private static let prominentInk = UIColor { traits in
        let tint = HQPalette.tint.resolvedColor(with: traits)
        guard traits.userInterfaceStyle == .dark else { return tint }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        tint.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r * 0.7, green: g * 0.7, blue: b * 0.7, alpha: a)
    }

    /// One pill's look: glass (or the tint's prominent glass when `picked`) with the look off, the desktop's flat piece on.
    private static func pillConfiguration(picked: Bool) -> UIButton.Configuration {
        var config: UIButton.Configuration
        if Theme.isDesktop {
            config = .filled()
            config.cornerStyle = .fixed
            config.background.cornerRadius = DesktopRows.radius
            config.baseBackgroundColor = picked ? HQPalette.tint : HQPalette.fill3
        } else {
            config = picked ? .hqProminentGlass() : .hqGlass()
            config.cornerStyle = .capsule
            if picked { config.baseBackgroundColor = prominentInk }
        }
        config.baseForegroundColor = picked ? HQPalette.onTint : HQPalette.label
        return config
    }

    private static func sized(_ button: UIButton, square: Bool) -> UIButton {
        let height = pillHeight
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true
        if square { button.widthAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true }
        return button
    }

    private func makeChip(_ page: DashboardPage, selected: Bool, count: Int) -> UIButton {
        var config = Self.pillConfiguration(picked: selected)
        let base = HQFont.preferred(Theme.isDesktop ? .footnote : .subheadline)
        let font = UIFont(descriptor: base.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.medium],
        ]), size: 0)
        config.attributedTitle = AttributedString(page.name, attributes: AttributeContainer([.font: font]))
        config.titleLineBreakMode = .byTruncatingTail
        // Large text grows the pill, never touching its edge.
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14)
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.onSelect?(page.id) })
        if !Theme.isDesktop { button.tintColor = Self.prominentInk }
        button.menu = menuFor?(page)
        button.showsMenuAsPrimaryAction = false
        button.accessibilityIdentifier = "dashboard.page.\(page.id == DashboardPage.mainId ? "main" : page.name)"
        button.accessibilityLabel = page.name
        button.accessibilityValue = count == 1 ? "1 tile" : "\(count) tiles"
        if selected { button.accessibilityTraits.insert(.selected) }
        return Self.sized(button, square: false)
    }

    /// ＋ and ⋯: round pills of the same glass, their marks in the secondary label colour.
    private static func symbolConfiguration(_ symbol: String) -> UIButton.Configuration {
        var config = pillConfiguration(picked: false)
        config.image = UIImage(systemName: symbol)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            textStyle: Theme.isDesktop ? .footnote : .subheadline, scale: .small)
        config.baseForegroundColor = HQPalette.label2
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        return config
    }

    private func makeAdd() -> UIButton {
        let button = UIButton(configuration: Self.symbolConfiguration("plus"),
                              primaryAction: UIAction { [weak self] _ in self?.onAdd?() })
        button.accessibilityIdentifier = "dashboard.page.add"
        button.accessibilityLabel = "New Page"
        return Self.sized(button, square: true)
    }

    /// [header-menus] The shown page's hold menu, a tap away: drawn as the ＋, titled with the page's name (away from the
    /// name, the menu says which page it acts on; Main's hold menu has no title of its own).
    private func makeMore(_ page: DashboardPage, menu: UIMenu) -> UIButton {
        let button = UIButton(configuration: Self.symbolConfiguration("ellipsis"))
        button.menu = UIMenu(title: page.name, children: menu.children)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityIdentifier = "dashboard.page.menu"
        button.accessibilityLabel = "Actions for \(page.name)"
        return Self.sized(button, square: true)
    }
}
