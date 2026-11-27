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
            case .glass: DesktopTabBar.paperPhone ? Glass.phoneBarHeight : Glass.barHeight
            case .sidebar: 0
            }
        }
    }

    /// [mac] The glass capsule's measures (the system bar on macOS 27, in the iPad points the Mac draws at 77 %).
    enum Glass {
        static let capsuleHeight: CGFloat = 62
        /// From the column's sides and bottom. [paper-solid] On the iPhone the system bar's own: 21 pt in from the
        /// sides, 21 pt over the screen's foot (8 on a phone with a Home button, no inset under the bar).
        static var margin: CGFloat { DesktopTabBar.paperPhone ? 21 : 10 }
        static let barHeight: CGFloat = capsuleHeight + 10
        /// [paper-solid] The bar's height over the window's bottom inset on the iPhone (the capsule starts where the
        /// system's did: 83 pt from the foot with a 34 pt inset, as the system bar).
        static var phoneBarHeight: CGFloat {
            let inset = DesktopTabBar.lastInset
            return capsuleHeight + (inset > 0 ? 21 : 8) - inset
        }
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
    static var wanted: Style? { style(desktopLook: Theme.isDesktop, mac: onMac) ?? (paperPhone ? .glass : nil) }

    /// [paper-solid] Paper on the iPhone: this bar's floating capsule (the Mac's, at the iPhone's measures) drawn
    /// solid, standing in for the system's. iOS 26 draws its floating bar's glass on its platter's own layer and keeps
    /// it whatever the bar's appearance says, so the system bar cannot be made solid. The iPad keeps the system bar.
    static var paperPhone: Bool { !onMac && UIDevice.current.userInterfaceIdiom == .phone && Theme.solidChrome }
    /// The window's bottom inset the bar last measured (`Glass.phoneBarHeight`).
    fileprivate(set) static var lastInset: CGFloat = 0

    private weak var host: UITabBarController?
    private let desktopFrost = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let desktopVeil = UIView()
    private let stack = UIStackView()
    private let topHairline = UIView()
    private var buttons: [TabButton] = []
    private var badgeWatch: [NSKeyValueObservation] = []
    private var bottomConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    private var themeToken: NSObjectProtocol?
    private var a11yToken: NSObjectProtocol?
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
        desktopFrost.accessibilityIdentifier = "desktop-tab-bar.frost"
        desktopFrost.isUserInteractionEnabled = false
        desktopFrost.translatesAutoresizingMaskIntoConstraints = false
        desktopVeil.isUserInteractionEnabled = false
        desktopVeil.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        desktopVeil.frame = desktopFrost.contentView.bounds
        desktopFrost.contentView.addSubview(desktopVeil)
        addSubview(desktopFrost)
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        topHairline.isUserInteractionEnabled = false
        topHairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topHairline)
        NSLayoutConstraint.activate([
            desktopFrost.leadingAnchor.constraint(equalTo: leadingAnchor), desktopFrost.trailingAnchor.constraint(equalTo: trailingAnchor),
            desktopFrost.topAnchor.constraint(equalTo: topAnchor), desktopFrost.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.heightAnchor.constraint(equalToConstant: Self.barHeight),
            topHairline.leadingAnchor.constraint(equalTo: leadingAnchor), topHairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            topHairline.topAnchor.constraint(equalTo: topAnchor), topHairline.heightAnchor.constraint(equalToConstant: HQShape.hairline),
        ])
        themeToken = NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        a11yToken = NotificationCenter.default.addObserver(forName: HQAccessibility.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recolor() }
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self, UITraitPreferredContentSizeCategory.self, UITraitAccessibilityContrast.self]) {
            (bar: DesktopTabBar, _) in bar.recolor()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        if let themeToken { NotificationCenter.default.removeObserver(themeToken) }
        if let a11yToken { NotificationCenter.default.removeObserver(a11yToken) }
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
        if Self.lastInset != inset {
            Self.lastInset = inset
            if Self.paperPhone { applyInsets() }   // [paper-solid] the phone bar's height over the inset changed
        }
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
            accessibilityIdentifier = Self.paperPhone ? "paper-tab-bar" : "mac-tab-bar"   // [paper-solid]
            let glass = UIVisualEffectView(effect: Self.paperPhone ? nil : UIGlassEffect(style: .regular))   // [paper-solid]
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
    /// [paper-solid] The selected tab on Paper's solid capsule: its soft grey (as its picked pill), lighter in dark.
    static let paperSelection = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.1) : UIColor(white: 0, alpha: 0.06)
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
        let pillRects = centres.map { CGRect(x: $0 - pill / 2, y: Glass.inset, width: pill, height: Glass.buttonHeight) }
        let capsuleBounds = CGRect(origin: .zero, size: capsule.size)
        for (index, button) in buttons.enumerated() {
            // Each button takes its share of the capsule (the ends reach its edges); its icon and label sit at the centre.
            let left = index == 0 ? 0 : (centres[index - 1] + centres[index]) / 2
            let right = index == buttons.count - 1 ? capsule.width : (centres[index] + centres[index + 1]) / 2
            button.frame = CGRect(x: left, y: Glass.inset, width: right - left, height: Glass.buttonHeight)
            button.centreOffset = centres[index] - (left + right) / 2
            button.glassPillGeometry = (
                pill: pillRects[index].offsetBy(dx: -left, dy: -Glass.inset),
                prevPill: index > 0 ? pillRects[index - 1].offsetBy(dx: -left, dy: -Glass.inset) : nil,
                nextPill: index + 1 < pillRects.count ? pillRects[index + 1].offsetBy(dx: -left, dy: -Glass.inset) : nil,
                capsule: capsuleBounds.offsetBy(dx: -left, dy: -Glass.inset)
            )
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
            UIView.animate(withDuration: HQMotion.hover, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { // motion-ok: hover fill fades opacity only
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
            Haptics.play(.selection)   // [tab-haptic] a second tap ticks too, as the system bar's
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
            desktopFrost.isHidden = true
            topHairline.isHidden = true
            if let platter {
                // [paper-solid] Paper's phone bar: its raised card inside a hairline, no glass.
                let solid = Self.paperPhone
                if solid, platter.effect != nil { platter.effect = nil }
                if !solid, platter.effect == nil { platter.effect = UIGlassEffect(style: .regular) }
                platter.backgroundColor = solid ? ChatPalette.promptCard : nil
                platter.layer.borderWidth = solid ? HQShape.hairline : 0
                platter.layer.borderColor = ChatPalette.strokeSecondary.resolvedColor(with: traitCollection).cgColor
                selectionPill.backgroundColor = solid ? Self.paperSelection : Self.selectionFill
            }
            setNeedsLayout()
        } else {
            let dark = traitCollection.userInterfaceStyle == .dark
            let surface = dark ? ChatPalette.elevated : ChatPalette.sidebar
            let solid = HQAccessibility.reduceTransparency
            // Crisp Frosted Chrome: plain systemThinMaterial blur + 76 % skin-tinted veil + whisper top hairline.
            backgroundColor = .clear
            desktopFrost.isHidden = false
            if solid {
                if desktopFrost.effect != nil { desktopFrost.effect = nil }
                desktopVeil.backgroundColor = surface
            } else {
                if desktopFrost.effect == nil { desktopFrost.effect = UIBlurEffect(style: .systemThinMaterial) }
                desktopVeil.backgroundColor = DesktopFrost.tint(surface, alpha: DesktopFrost.tabBarTintAlpha)
            }
            topHairline.isHidden = false
            topHairline.backgroundColor = DesktopFrost.whisperLine
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
    /// Glass capsule geometry in this button's coordinates, so badges clamp clear of neighbouring pills and capsule edges.
    var glassPillGeometry: (pill: CGRect, prevPill: CGRect?, nextPill: CGRect?, capsule: CGRect)? {
        didSet { if style == .glass { setNeedsLayout() } }
    }

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
            // below it; the badge is placed in `layoutSubviews` via `TabBadgeLayout` so it stays clear of adjacent pills.
            // [paper-solid] Paper's phone bar: the iPhone system bar's (the symbol's middle 20 pt down, a 12 pt label
            // line 35 pt down).
            let phone = DesktopTabBar.paperPhone
            let centre = icon.centerXAnchor.constraint(equalTo: centerXAnchor)
            centreX = centre
            badgeLabel.translatesAutoresizingMaskIntoConstraints = true
            NSLayoutConstraint.activate([
                centre, icon.centerYAnchor.constraint(equalTo: topAnchor, constant: 20),
                label.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
                label.topAnchor.constraint(equalTo: topAnchor, constant: phone ? 35 : 31),
                label.heightAnchor.constraint(equalToConstant: phone ? 12 : 16),
                label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -4),
            ])
            badgeLabel.layer.cornerRadius = TabBadgeLayout.badgeHeight / 2
            badgeLabel.layer.cornerCurve = .continuous
            if let image = item.image, image.isSymbolImage {
                icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: phone ? 19 : 18, weight: .medium, scale: .large)
            }
            label.text = item.title
        } else {
            // The badge grows rightwards from just inside the glyph's right edge, as the system bar's does: centred on
            // the icon's corner, "3" hid half the robot and "128" most of the Sessions bubbles. Lower priority on leading
            // lets wide counts ("99+") tuck inward rather than touching the neighbouring tab or bar edge.
            let badgeLeading = badgeLabel.leadingAnchor.constraint(equalTo: icon.centerXAnchor, constant: Self.badgeOffset)
            badgeLeading.priority = .defaultHigh
            self.badgeLeading = badgeLeading
            NSLayoutConstraint.activate([
                icon.centerXAnchor.constraint(equalTo: centerXAnchor), icon.topAnchor.constraint(equalTo: topAnchor, constant: 7),
                icon.heightAnchor.constraint(equalToConstant: 22), icon.widthAnchor.constraint(equalToConstant: 30),
                label.heightAnchor.constraint(lessThanOrEqualToConstant: 16),
                label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 3),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                badgeLeading,
                badgeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
                badgeLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
                badgeLabel.centerYAnchor.constraint(equalTo: icon.topAnchor, constant: 3),
                badgeLabel.heightAnchor.constraint(equalToConstant: 16), badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            ])
            badgeLabel.layer.cornerRadius = 8
        }
        badge = item.badgeValue
        showBadge()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if style == .glass { positionGlassBadge() }
    }

    private func positionGlassBadge() {
        guard !badgeLabel.isHidden else { return }
        let height = TabBadgeLayout.badgeHeight
        let width = max(height, ceil(badgeLabel.intrinsicContentSize.width))
        let iconRect = icon.frame.isEmpty ? CGRect(x: bounds.midX + centreOffset - 12, y: 8, width: 24, height: 24) : icon.frame
        let slot: TabBadgeLayout.Slot
        if let g = glassPillGeometry {
            slot = TabBadgeLayout.Slot(icon: iconRect, pill: g.pill, prevPill: g.prevPill, nextPill: g.nextPill, capsule: g.capsule)
        } else {
            slot = TabBadgeLayout.Slot(icon: iconRect, pill: bounds)
        }
        badgeLabel.frame = TabBadgeLayout.frame(for: slot, badgeSize: CGSize(width: width, height: height))
    }

    private func showBadge() {
        badgeLabel.isHidden = (badge ?? "").isEmpty
        badgeLabel.text = badge
        badgeLabel.font = style == .glass
            ? UIFont.systemFont(ofSize: 12, weight: .semibold)       // a11y-font-ok: compact capsule tab bar badge
            : UIFont.systemFont(ofSize: 11, weight: .semibold)   // a11y-font-ok: Desktop Look badge is a fixed size like the desktop app
        accessibilityValue = (badge ?? "").isEmpty ? item.accessibilityValue : "\(badge ?? "") new"
        if style == .glass { setNeedsLayout() }
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
            label.font = DesktopTabBar.paperPhone
                ? UIFont.systemFont(ofSize: 10, weight: .medium)   // a11y-font-ok: the iPhone system tab bar's label (Paper's stand-in)
                : HQFont.macTabLabel
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
        label.attributedText = NSAttributedString(string: item.title ?? "", attributes: [
            .font: HQFont.face(ofSize: size, weight: .medium), .foregroundColor: colour,
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
