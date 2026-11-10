// desktoplook: the docked tab bar of the Desktop Look (spec 3x-desktoplook §5.3). iOS 26's own tab bar is a floating
// glass capsule and cannot be drawn docked and solid, so with the look on the system bar is hidden and this plain bar
// sits at the bottom edge: the same tabs, order, icons, badges and accessibility identifiers. With the look off it is
// not in the view tree at all.
//
// [mac] On the Mac the iOS look uses it too, as a floating glass capsule (`Style.glass`) drawn like iOS 26's bar
// (owner 2026-10-24, "I also don't like placement of the menu at the top": macOS 26 put the system bar at the top of
// the list, macOS 27 at the bottom). The app draws it itself so every macOS puts it at the bottom of the list.

import UIKit

final class DesktopTabBar: UIView {
    static let barHeight: CGFloat = 50

    /// How the docked bar draws: the Desktop Look's plain docked bar, or the Mac's floating glass capsule.
    enum Style: Equatable {
        case desktop
        /// [mac] The iOS look on the Mac: iOS 26's floating glass bar, measured on macOS 27 (10 pt from the column's
        /// sides and bottom, 62 tall, 96 × 54 buttons and selection, symbols 18 pt medium large, 13 pt labels).
        case glass
        /// [mac] No bar in the list column at all: the window's sidebar (`MacSidebar`) lists the tabs, as Mail and
        /// Music do. Owner 2026-10-25: the bottom capsule was "a crowded row of overlapping touch-style pills".
        case sidebar

        /// The room children keep clear of the bar (over the window's own bottom inset).
        var height: CGFloat {
            switch self {
            case .desktop: DesktopTabBar.barHeight
            case .glass: Glass.barHeight
            case .sidebar: 0
            }
        }
    }

    /// [mac] The glass capsule's measures (the system bar on macOS 27, in the iPad points the Mac draws at 77 %).
    enum Glass {
        static let capsuleHeight: CGFloat = 62
        static let margin: CGFloat = 10            // from the column's sides and bottom
        static let barHeight: CGFloat = capsuleHeight + margin
        static let inset: CGFloat = 4              // buttons inside the capsule
        static let buttonHeight: CGFloat = 54
        static let maxButtonWidth: CGFloat = 96

        /// The selection pill's width and each button's centre across the capsule's `width` for `count` tabs: the
        /// system spreads 96-wide buttons from edge to edge (they overlap); a narrower column narrows them.
        static func layout(width: CGFloat, count: Int) -> (pill: CGFloat, centres: [CGFloat]) {
            guard count > 0 else { return (0, []) }
            let room = max(0, width - inset * 2)
            let pill = min(maxButtonWidth, room / CGFloat(count) + 14)
            guard count > 1 else { return (pill, [width / 2]) }
            let step = (room - pill) / CGFloat(count - 1)
            return (pill, (0..<count).map { inset + pill / 2 + step * CGFloat($0) })
        }
    }

    /// The docked bar in use for a look on a platform; nil: the system's own tab bar. The Mac has its sidebar in
    /// either look.
    static func style(desktopLook: Bool, mac: Bool) -> Style? {
        if mac { return .sidebar }
        return desktopLook ? .desktop : nil
    }

    static var onMac: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }

    /// The docked bar the app's current look asks for (nil: the system bar). On the iPhone and iPad this is the
    /// Desktop Look exactly.
    static var wanted: Style? { style(desktopLook: Theme.isDesktop, mac: onMac) }

    private weak var host: UITabBarController?
    private let stack = UIStackView()
    private var buttons: [TabButton] = []
    private var badgeWatch: [NSKeyValueObservation] = []
    private var bottomConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    private var themeToken: NSObjectProtocol?
    /// A pushed page that hides the bottom bar (a chat) is on top.
    private(set) var coveredByPage = false
    private(set) var style: Style = .desktop
    /// [mac] The glass style's capsule, its selection pill and the pointer's hover pill.
    private var platter: UIVisualEffectView?
    private let selectionPill = UIView()
    private let hoverPill = UIView()
    private var hoveredIndex: Int?
    /// The bar is in the view tree standing in for the system bar.
    var isDocked: Bool { superview != nil }

    init(host: UITabBarController) {
        self.host = host
        super.init(frame: .zero)
        accessibilityIdentifier = "desktop-tab-bar"
        accessibilityTraits = .tabBar
        accessibilityContainerType = .semanticGroup
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.heightAnchor.constraint(equalToConstant: Self.barHeight),
        ])
        themeToken = NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self, UITraitPreferredContentSizeCategory.self]) {
            (bar: DesktopTabBar, _) in bar.recolor()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        if let themeToken { NotificationCenter.default.removeObserver(themeToken) }
    }

    /// Shows or removes the bar for the current theme and rebuilds its buttons from the host's tabs. `wanted`: the bar
    /// the look asks for (tests pass one).
    func sync(wanted: Style? = DesktopTabBar.wanted) {
        guard let host else { return }
        if wanted == .sidebar {
            // [mac] Neither bar: the sidebar beside the list takes the tabs, and the list runs to the window's foot.
            style = .sidebar
            removeFromSuperview()
            for child in host.viewControllers ?? [] where child.additionalSafeAreaInsets.bottom != 0 { child.additionalSafeAreaInsets.bottom = 0 }
            if !host.isTabBarHidden { host.setTabBarHidden(true, animated: false) }
            return
        }
        if let wanted {
            if wanted != style {
                style = wanted
                restyle()
            }
            if superview == nil {
                translatesAutoresizingMaskIntoConstraints = false
                host.view.addSubview(self)
                let height = heightAnchor.constraint(equalToConstant: style.height)
                heightConstraint = height
                NSLayoutConstraint.activate([
                    leadingAnchor.constraint(equalTo: host.view.leadingAnchor), trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
                    bottomAnchor.constraint(equalTo: host.view.bottomAnchor), height,
                ])
            }
            host.view.bringSubviewToFront(self)
            if !host.isTabBarHidden { host.setTabBarHidden(true, animated: false) }
            rebuild()
            noteTop(of: host.selectedViewController as? UINavigationController, animated: false)
        } else {
            guard superview != nil || host.isTabBarHidden else { return }
            removeFromSuperview()
            for child in host.viewControllers ?? [] { child.additionalSafeAreaInsets.bottom = 0 }
            let covered = ((host.selectedViewController as? UINavigationController)?.viewControllers ?? []).contains(where: \.hidesBottomBarWhenPushed)
            if host.isTabBarHidden, !covered { host.setTabBarHidden(false, animated: false) }
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateHeight()
    }

    private func updateHeight() {
        let inset = host?.view.window?.safeAreaInsets.bottom ?? superview?.safeAreaInsets.bottom ?? 0
        heightConstraint?.constant = style.height + inset
    }

    /// Between the Desktop Look's docked bar and the Mac's glass capsule (Settings › Appearance, live).
    private func restyle() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        badgeWatch = []
        hoveredIndex = nil
        switch style {
        case .desktop:
            platter?.removeFromSuperview()
            platter = nil
            stack.isHidden = false
            accessibilityIdentifier = "desktop-tab-bar"
        case .glass:
            stack.isHidden = true
            backgroundColor = .clear
            accessibilityIdentifier = "mac-tab-bar"
            let effect = UIGlassEffect(style: .regular)
            let glass = UIVisualEffectView(effect: effect)
            glass.cornerConfiguration = .capsule()
            for pill in [hoverPill, selectionPill] {
                pill.isUserInteractionEnabled = false
                pill.layer.cornerCurve = .continuous
                pill.accessibilityElementsHidden = true
                glass.contentView.addSubview(pill)
            }
            hoverPill.alpha = 0
            hoverPill.backgroundColor = Self.hoverFill
            selectionPill.backgroundColor = Self.selectionFill
            addSubview(glass)
            platter = glass
            #if targetEnvironment(macCatalyst)
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
            glass.addGestureRecognizer(hover)
            #endif
        case .sidebar:
            break
        }
        heightConstraint?.constant = style.height
        updateHeight()
        setNeedsLayout()
    }

    /// The selection behind the selected tab: a soft grey pill (measured: 7 % black over the light capsule, the page's
    /// near-black in dark).
    static let selectionFill = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.5) : UIColor(white: 0, alpha: 0.075)
    }
    /// [mac] The pointer over a tab (MacHover's button fill).
    static let hoverFill = UIColor { traits in
        UIColor.label.resolvedColor(with: traits).withAlphaComponent(0.08)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard style == .glass, let platter else { return }
        let capsule = CGRect(x: Glass.margin, y: 0, width: max(0, bounds.width - Glass.margin * 2), height: Glass.capsuleHeight)
        if platter.frame != capsule { platter.frame = capsule }
        let (pill, centres) = Glass.layout(width: capsule.width, count: buttons.count)
        for (index, button) in buttons.enumerated() {
            // Each button takes its share of the capsule (the ends reach its edges); its icon and label sit at the centre.
            let left = index == 0 ? 0 : (centres[index - 1] + centres[index]) / 2
            let right = index == buttons.count - 1 ? capsule.width : (centres[index] + centres[index + 1]) / 2
            button.frame = CGRect(x: left, y: Glass.inset, width: right - left, height: Glass.buttonHeight)
            button.centreOffset = centres[index] - (left + right) / 2
        }
        for view in [selectionPill, hoverPill] { view.layer.cornerRadius = Glass.buttonHeight / 2 }
        placePill(selectionPill, at: host?.selectedIndex, width: pill, centres: centres)
        placePill(hoverPill, at: hoveredIndex, width: pill, centres: centres)
    }

    private func placePill(_ view: UIView, at index: Int?, width: CGFloat, centres: [CGFloat]) {
        guard let index, centres.indices.contains(index) else {
            if view === selectionPill { view.isHidden = true }
            return
        }
        view.isHidden = false
        let frame = CGRect(x: centres[index] - width / 2, y: Glass.inset, width: width, height: Glass.buttonHeight)
        if view.frame != frame { view.frame = frame }
    }

    #if targetEnvironment(macCatalyst)
    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        guard let platter else { return }
        let x = recognizer.location(in: platter.contentView).x
        let index: Int? = switch recognizer.state {
        case .began, .changed: buttons.firstIndex { $0.frame.minX <= x && x < $0.frame.maxX }
        default: nil
        }
        // The selected tab already has its pill.
        let shown = index == host?.selectedIndex ? nil : index
        guard shown != hoveredIndex else { return }
        if let shown {
            hoveredIndex = shown
            hoverPill.layer.removeAllAnimations()
            setNeedsLayout()
            layoutIfNeeded()
            hoverPill.alpha = 1
        } else {
            hoveredIndex = nil
            UIView.animate(withDuration: 0.06, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { // motion-ok: hover fill fades opacity only
                self.hoverPill.alpha = 0
            }
        }
    }
    #endif

    /// The glass bar is a capsule floating over the list: only the capsule takes clicks, the list shows and answers
    /// around it.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard style == .glass, let platter else { return super.point(inside: point, with: event) }
        return platter.frame.contains(point)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateHeight()
        recolor()
    }

    func rebuild() {
        guard let host, superview != nil else { return }
        badgeWatch = []
        buttons.forEach { $0.removeFromSuperview() }
        buttons = (host.viewControllers ?? []).enumerated().map { index, controller in
            let item = controller.tabBarItem ?? UITabBarItem()
            let button = TabButton(item: item, style: style)
            button.addAction(UIAction { [weak self, weak button] _ in
                self?.select(index)
                button?.playMotion()          // [tabmotion] after the select, in the colour it turns
            }, for: .touchUpInside)
            if style == .glass, let platter { platter.contentView.addSubview(button) } else { stack.addArrangedSubview(button) }
            badgeWatch.append(item.observe(\.badgeValue, options: [.new]) { [weak button] item, _ in
                MainActor.assumeIsolated { button?.badge = item.badgeValue }
            })
            // The Jobs tab's icon turns while jobs run (`TabIcons.jobsRunning`).
            badgeWatch.append(item.observe(\.image, options: [.new]) { [weak button] _, _ in
                MainActor.assumeIsolated { button?.imageChanged() }
            })
            return button
        }
        updateHeight()
        recolor()
        applyInsets()
        setNeedsLayout()
    }

    /// A tab picked on a bar of the app's own (this one or the Mac's sidebar), as the system bar picks it: a second
    /// pick of the selected tab goes back to its root. The tab now on show, nil when nothing changed.
    @discardableResult static func select(_ index: Int, in host: UITabBarController, animated: Bool = true) -> UIViewController? {
        guard let controllers = host.viewControllers, index < controllers.count else { return nil }
        let target = controllers[index]
        if host.selectedIndex == index {
            // The system bar's second tap: back to the tab's root; [tabretap] at the root already, to the page's top.
            if !TabRetap.scrollToTop(target, animated: animated) {
                (target as? UINavigationController)?.popToRootViewController(animated: animated)
            }
            return nil
        }
        guard host.delegate?.tabBarController?(host, shouldSelect: target) ?? true else { return nil }
        Haptics.play(.selection)
        host.selectedIndex = index
        host.delegate?.tabBarController?(host, didSelect: target)
        return target
    }

    #if DEBUG
    /// [tabmotion] `-HQDebugTabMotion`: the tab's motion without a tap.
    func playMotion(at index: Int) {
        if buttons.indices.contains(index) { buttons[index].playMotion() }
    }
    #endif

    private func select(_ index: Int) {
        guard let host, let target = Self.select(index, in: host) else { return }
        recolor()
        noteTop(of: target as? UINavigationController, animated: false)
    }

    func recolor() {
        guard let host else { return }
        if style == .glass {
            backgroundColor = .clear
            setNeedsLayout()
        } else {
            let dark = traitCollection.userInterfaceStyle == .dark
            // The raised panel (owner's pick): the sidebar in light, the elevated surface in dark; no line over it.
            backgroundColor = dark ? ChatPalette.elevated : ChatPalette.sidebar
        }
        for (index, button) in buttons.enumerated() { button.apply(selected: index == host.selectedIndex) }
    }

    /// [mac] The selection pill slides to the newly selected tab, as the system's does.
    private func movePill() {
        hoveredIndex = nil
        hoverPill.alpha = 0
        HQMotion.spring(duration: 0.35, damping: 0.85, changes: { [weak self] in
            self?.setNeedsLayout()
            self?.layoutIfNeeded()
        })
    }

    /// Children clear the bar; a page that hides the bottom bar gets the whole screen.
    private func applyInsets() {
        guard let host, superview != nil else { return }
        for child in host.viewControllers ?? [] {
            let inset: CGFloat = coveredByPage && child === host.selectedViewController ? 0 : style.height
            if child.additionalSafeAreaInsets.bottom != inset { child.additionalSafeAreaInsets.bottom = inset }
        }
    }

    /// A navigation stack is about to show `page`: hide under a page that asks for no bottom bar (the chat), as the
    /// system bar does, and come back when it is popped.
    func navigationWillShow(_ page: UIViewController, in navigation: UINavigationController, animated: Bool) {
        guard superview != nil, navigation === host?.selectedViewController else { return }
        let index = navigation.viewControllers.firstIndex(of: page) ?? navigation.viewControllers.count - 1
        let covered = navigation.viewControllers.prefix(index + 1).contains(where: \.hidesBottomBarWhenPushed) || page.hidesBottomBarWhenPushed
        setCovered(covered, animated: animated, coordinator: navigation.transitionCoordinator)
    }

    /// A navigation stack finished showing a page: the bar settles on what the stack now shows.
    func navigationDidShow(in navigation: UINavigationController) {
        guard superview != nil, navigation === host?.selectedViewController else { return }
        noteTop(of: navigation, animated: false)
    }

    private func noteTop(of navigation: UINavigationController?, animated: Bool) {
        let covered = (navigation?.viewControllers ?? []).contains(where: \.hidesBottomBarWhenPushed)
        setCovered(covered, animated: animated, coordinator: nil)
    }

    private func setCovered(_ covered: Bool, animated: Bool, coordinator: UIViewControllerTransitionCoordinator?) {
        guard covered != coveredByPage else {
            applyInsets()
            // Owner 2026-10-20 ("the text input field gets replaced for the menu"): a transition's slide that never ran,
            // or a stale one that landed after the next push, left the bar drawn over the chat's composer while the chat
            // had already taken the whole screen. Outside a transition the bar is drawn as the stack says.
            if coordinator == nil { draw(covered: covered) }
            return
        }
        coveredByPage = covered
        isUserInteractionEnabled = !covered
        accessibilityElementsHidden = covered
        applyInsets()
        let queued = animated && coordinator?.animate(alongsideTransition: { [weak self] _ in self?.draw(covered: covered) },
                                                      completion: { [weak self] _ in
            // A back swipe let go, or another push or pop landed meanwhile: settle on the page now on top.
            guard let self else { return }
            self.noteTop(of: self.host?.selectedViewController as? UINavigationController, animated: false)
        }) == true
        if !queued { draw(covered: covered) }
    }

    private func draw(covered: Bool) {
        let shift = covered ? CGAffineTransform(translationX: 0, y: max(bounds.height, style.height)) : .identity
        if transform != shift { transform = shift }
        let shown: CGFloat = covered ? 0 : 1
        if alpha != shown { alpha = shown }
    }

    func selectionChanged() {
        if style == .glass, superview != nil { movePill() }
        recolor()
        noteTop(of: host?.selectedViewController as? UINavigationController, animated: false)
    }
}

/// One tab: icon over label, the desktop's small tracked capitals; on the Mac's glass bar the system's Title Case
/// labels and symbol size.
private final class TabButton: UIControl {
    private let icon = TabIconView()
    private let label = UILabel()
    private let badgeLabel = TabBadgeLabel()
    private let item: UITabBarItem
    private let style: DesktopTabBar.Style
    private var drawnScale: CGFloat?
    private var centreX: NSLayoutConstraint?
    private var badgeLeading: NSLayoutConstraint?
    /// Desktop Look: the badge's left edge from the icon's centre at 100 %, 3 pt inside a glyph's right edge (the
    /// 17 pt symbols are about 20 pt wide).
    private static let badgeOffset: CGFloat = 7

    var badge: String? { didSet { showBadge() } }
    /// [mac] Glass: where the tab's centre sits from the button's own (the ends of the bar are wider than their tab).
    var centreOffset: CGFloat = 0 { didSet { if centreX?.constant != centreOffset { centreX?.constant = centreOffset } } }

    init(item: UITabBarItem, style: DesktopTabBar.Style = .desktop) {
        self.item = item
        self.style = style
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityIdentifier = item.accessibilityIdentifier
        accessibilityLabel = item.title
        showsLargeContentViewer = true
        largeContentTitle = item.title
        largeContentImage = item.image
        scalesLargeContentImage = true
        addInteraction(UILargeContentViewerInteraction())
        icon.contentMode = .center          // every symbol at its own drawn size in one 22 pt box
        icon.icon = item.image
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        badgeLabel.textColor = .white
        badgeLabel.backgroundColor = style == .glass ? .systemRed : ChatPalette.alertRed
        badgeLabel.textAlignment = .center
        badgeLabel.layer.masksToBounds = true
        for view in [icon, label, badgeLabel] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        if style == .glass {
            // The system bar on macOS 27: the symbol's middle 20 pt below the button's top, the 16 pt label line 31 pt
            // below it, a 20 pt badge 14 pt right of the tab's centre and 2 pt below the top.
            let centre = icon.centerXAnchor.constraint(equalTo: centerXAnchor)
            centreX = centre
            NSLayoutConstraint.activate([
                centre, icon.centerYAnchor.constraint(equalTo: topAnchor, constant: 20),
                label.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
                label.topAnchor.constraint(equalTo: topAnchor, constant: 31), label.heightAnchor.constraint(equalToConstant: 16),
                label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -4),
                badgeLabel.leadingAnchor.constraint(equalTo: icon.centerXAnchor, constant: 14),
                badgeLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
                badgeLabel.heightAnchor.constraint(equalToConstant: 20), badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
            ])
            badgeLabel.layer.cornerRadius = 10
            if let image = item.image, image.isSymbolImage {
                icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium, scale: .large)
            }
            label.text = item.title
        } else {
            // The badge grows rightwards from just inside the glyph's right edge, as the system bar's does: centred on
            // the icon's corner, "3" hid half the robot and "128" most of the Sessions bubbles.
            let badgeLeading = badgeLabel.leadingAnchor.constraint(equalTo: icon.centerXAnchor, constant: Self.badgeOffset)
            self.badgeLeading = badgeLeading
            NSLayoutConstraint.activate([
                icon.centerXAnchor.constraint(equalTo: centerXAnchor), icon.topAnchor.constraint(equalTo: topAnchor, constant: 7),
                icon.heightAnchor.constraint(equalToConstant: 22), icon.widthAnchor.constraint(equalToConstant: 30),
                label.heightAnchor.constraint(lessThanOrEqualToConstant: 16),
                label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 3),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                badgeLeading,
                badgeLabel.centerYAnchor.constraint(equalTo: icon.topAnchor, constant: 3),
                badgeLabel.heightAnchor.constraint(equalToConstant: 16), badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            ])
            badgeLabel.layer.cornerRadius = 8
        }
        badge = item.badgeValue
        showBadge()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }


    private func showBadge() {
        badgeLabel.isHidden = (badge ?? "").isEmpty
        badgeLabel.text = badge
        badgeLabel.font = style == .glass
            ? UIFont.systemFont(ofSize: 13, weight: .regular)       // a11y-font-ok: the system bar's badge on the Mac (13 iPad pt = 10 pt on screen)
            : UIFont.systemFont(ofSize: 11, weight: .semibold)   // a11y-font-ok: Desktop Look badge is a fixed size like the desktop app
        accessibilityValue = (badge ?? "").isEmpty ? item.accessibilityValue : "\(badge ?? "") new"
    }

    /// [tabmotion] The icon's tap motion (`TabMotion`).
    func playMotion() { TabMotion.play(in: icon, source: icon.icon) }

    func imageChanged() {
        showBadge()   // the Jobs tab's "N running" comes with its icon
        drawnScale = nil
        icon.icon = item.image
        largeContentImage = item.image
        apply(selected: accessibilityTraits.contains(.selected))
    }

    func apply(selected: Bool) {
        if style == .glass {
            // The system's colours: the accent for the selected tab, the label colour for the rest.
            let colour: UIColor = selected ? (tintColor ?? .tintColor) : .label
            icon.tintColor = colour
            label.font = HQFont.macTabLabel
            label.textColor = colour
            accessibilityTraits = selected ? [.button, .selected] : .button
            return
        }
        let colour = selected ? ChatPalette.tintText : ChatPalette.tabIdle
        let scale = min(HQFont.scale, 1.25)
        icon.tintColor = colour
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: TabIcons.pointSize * scale, weight: .regular)
        badgeLeading?.constant = Self.badgeOffset * scale   // the glyph grows with UI Scale; the badge stays at its edge
        // A drawn glyph (Bots, Kanban) ignores the symbol configuration: redraw it at the same size so it scales with UI Scale.
        if scale != drawnScale, let image = TabIcons.redrawn(item.image, pointSize: TabIcons.pointSize * scale) {
            icon.icon = image
            drawnScale = scale
        }
        let size = min(10 * HQFont.scale, 12.5)
        label.attributedText = NSAttributedString(string: (item.title ?? "").uppercased(), attributes: [
            .font: HQFont.face(ofSize: size, weight: .semibold), .kern: size * 0.06, .foregroundColor: colour,
        ])
        accessibilityTraits = selected ? [.button, .selected] : .button
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        if style == .glass { apply(selected: accessibilityTraits.contains(.selected)) }
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }
}

private final class TabBadgeLabel: UILabel {
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 8, height: size.height)
    }
}
