// desktoplook3: the Back button of the Desktop Look without iOS 26's glass circle (owner: "the Liquid Glass on the
// desktop look throws off the look a lot"). The system back button keeps its circle whatever `hidesSharedBackground`
// its `backBarButtonItem` has, so in the look a page's system back button is hidden and a plain bar button stands in
// its place: the same chevron (and the count the list gives its back title), a tap that pops (or runs the page's own
// `backAction`), a long press that lists the pages under it, the swipe back kept. With the look off none of it exists:
// the stand-in is taken away and the page's own `hidesBackButton` is put back.
//
// A page's own wish to hide Back (an edit mode) is kept apart from the look's: `setHidesBackButton` is exchanged on
// UINavigationItem (public methods only), recording what the page asked for; `intendedHidesBackButton` reads it.

import ObjectiveC
import UIKit

@MainActor enum DesktopBack {
    private static var installed = false
    private static let intentKey = malloc(1)!
    private static let standInKey = malloc(1)!
    private static let markKey = malloc(1)!
    private static let swipeKey = malloc(1)!
    private static let ownKey = malloc(1)!

    static func install() {
        guard !installed else { return }
        installed = true
        let type: AnyClass = UINavigationItem.self
        exchange(type, #selector(setter: UINavigationItem.hidesBackButton), #selector(UINavigationItem.hqSetHidesBackButton(_:)))
        exchange(type, #selector(UINavigationItem.setHidesBackButton(_:animated:)), #selector(UINavigationItem.hqSetHidesBackButton(_:animated:)))
        exchange(type, #selector(setter: UINavigationItem.leftBarButtonItems), #selector(UINavigationItem.hqSetLeftItems(_:)))
        exchange(type, #selector(setter: UINavigationItem.rightBarButtonItems), #selector(UINavigationItem.hqSetRightItems(_:)))
        exchange(type, #selector(setter: UINavigationItem.leftBarButtonItem), #selector(UINavigationItem.hqSetLeftItem(_:)))
        exchange(type, #selector(setter: UINavigationItem.rightBarButtonItem), #selector(UINavigationItem.hqSetRightItem(_:)))
        exchange(type, #selector(UINavigationItem.setLeftBarButtonItems(_:animated:)), #selector(UINavigationItem.hqSetLeftItems(_:animated:)))
        exchange(type, #selector(UINavigationItem.setRightBarButtonItems(_:animated:)), #selector(UINavigationItem.hqSetRightItems(_:animated:)))
    }

    private static func exchange(_ type: AnyClass, _ selector: Selector, _ hook: Selector) {
        guard let original = class_getInstanceMethod(type, selector), let replacement = class_getInstanceMethod(type, hook) else { return }
        method_exchangeImplementations(original, replacement)
    }

    /// [mac] Stress test 2026-10-28 #104 (review): the Mac stands in for the system Back in both looks. In the iOS look
    /// the system's was a 23 pt glass circle with no name; in the Desktop Look the stand-in was a bare chevron, because
    /// a bar item given both an image and a title draws only the image, so the title `refresh` set never showed. On the
    /// Mac the stand-in is a plain button with the chevron and the parent page's name (`macBackButton`).
    static var standsIn: Bool { Theme.isDesktop || DeviceWord.isMac }

    /// Back with a count (2026-10-30, owner: "too much padding inside it"). iOS 26 sets a Back title in a box at least
    /// 31 pt wide and centres a short one in it, so "‹ 2" was an 82 pt capsule (15 pt between the chevron and the "2",
    /// 27 pt after it), nearly as wide as "‹ Bots". The Desktop Look's stand-in drew no count at all (a bar item with
    /// an image draws no title). On the iPhone and iPad a count's Back is a fitted button of its own in both looks: in
    /// the iOS look on the bar's glass, in the Desktop Look flat. A Back with a name, or none, stays as it was.
    static func isCount(_ title: String?) -> Bool {
        guard let title, !title.isEmpty else { return false }
        return title.allSatisfy { $0.isASCII && ($0.isNumber || $0 == "+") }
    }

    private static func counts(_ previous: UINavigationItem?) -> Bool { !DeviceWord.isMac && isCount(previous?.backButtonTitle) }

    private static func isCountButton(_ back: UIBarButtonItem) -> Bool { back.customView is CountBackButton }

    // MARK: The page's own wish

    /// What the page itself asked for (`hidesBackButton` reads true while the look's stand-in shows).
    static func intendedHidesBackButton(_ item: UINavigationItem) -> Bool {
        (objc_getAssociatedObject(item, intentKey) as? NSNumber)?.boolValue ?? item.hidesBackButton
    }

    fileprivate static func record(_ hides: Bool, on item: UINavigationItem) {
        objc_setAssociatedObject(item, intentKey, NSNumber(value: hides), .OBJC_ASSOCIATION_RETAIN)
    }

    /// The value the system gets: the page's wish, or true while the stand-in is up.
    fileprivate static func effective(_ hides: Bool, on item: UINavigationItem) -> Bool {
        hides || standIn(of: item) != nil
    }

    /// Set by this file: the hooks pass it straight through (UIKit's setter calls the animated one itself).
    fileprivate static var settingRaw = false

    private static func setRaw(_ hides: Bool, on item: UINavigationItem) {
        settingRaw = true
        defer { settingRaw = false }
        item.hqSetHidesBackButton(hides)          // the original setter (the implementations were exchanged)
    }

        static func standIn(of item: UINavigationItem) -> UIBarButtonItem? {
        objc_getAssociatedObject(item, standInKey) as? UIBarButtonItem
    }

    static func isStandIn(_ button: UIBarButtonItem) -> Bool { (objc_getAssociatedObject(button, markKey) as? Bool) ?? false }

    /// A page's own `backAction` (its Back asks before leaving), wherever it is kept now: on the item, or held for the
    /// stand-in while one is up. [keys] Mac polish #20: Escape and ⌘[ run it, as a click on Back does.
    static func ownBackAction(of item: UINavigationItem) -> UIAction? {
        item.backAction ?? objc_getAssociatedObject(item, ownKey) as? UIAction
    }

    // MARK: The stand-in

    /// `item` is a page in `bar`'s stack, `previous` the page under it (nil for the stack's root: no Back).
    static func apply(_ item: UINavigationItem, under previous: UINavigationItem?, in bar: UINavigationBar, desktop: Bool) {
        var current = standIn(of: item)
        let intent = intendedHidesBackButton(item)
        let others = (item.leftBarButtonItems ?? []).filter { !isStandIn($0) }
        // The system shows Back when the page does not hide it and its own leading items (if any) supplement it.
        let look = desktop || DeviceWord.isMac   // [mac] #104: both looks on the Mac
        let counted = counts(previous)           // 2026-10-30: a count's Back is fitted in both looks
        let wanted = (look || counted) && previous != nil && !intent && (others.isEmpty || item.leftItemsSupplementBackButton)
        if wanted {
            // The count came or went: the other kind of stand-in in its place.
            if let shown = current, isCountButton(shown) != counted {
                objc_setAssociatedObject(item, standInKey, nil, .OBJC_ASSOCIATION_RETAIN)
                current = nil
            }
            let back = current ?? make(for: item, in: bar, counted: counted)
            if current == nil {
                record(intent, on: item)
                objc_setAssociatedObject(item, standInKey, back, .OBJC_ASSOCIATION_RETAIN)
            }
            back.hidesSharedBackground = !(counted && !desktop)   // the count's Back keeps the iOS look's glass
            // A page's own `backAction` shows the system Back whatever `hidesBackButton` says (Mac, iOS 26): it moves to
            // the stand-in while the stand-in is up.
            if let own = item.backAction {
                objc_setAssociatedObject(item, ownKey, own, .OBJC_ASSOCIATION_RETAIN)
                item.backAction = nil
            }
            refresh(back, previous: previous, item: item, in: bar)
            if (item.leftBarButtonItems ?? []).first !== back { item.hqSetLeftItems([back] + others) }
            if !item.hidesBackButton { setRaw(true, on: item) }
            keepSwipe(bar)
        } else if let current {
            objc_setAssociatedObject(item, standInKey, nil, .OBJC_ASSOCIATION_RETAIN)
            if let own = objc_getAssociatedObject(item, ownKey) as? UIAction {
                objc_setAssociatedObject(item, ownKey, nil, .OBJC_ASSOCIATION_RETAIN)
                item.backAction = own
            }
            if (item.leftBarButtonItems ?? []).contains(where: { $0 === current }) {
                item.hqSetLeftItems(others.isEmpty ? nil : others)
            }
            if item.hidesBackButton != intent { setRaw(intent, on: item) }
        }
        // Off the look the page's own value is the system's again: nothing is kept to read later.
        if !look, standIn(of: item) == nil { objc_setAssociatedObject(item, intentKey, nil, .OBJC_ASSOCIATION_RETAIN) }
    }

    // MARK: Bars that may need another pass

    /// Bars seen laying out in the look. A page that changes its items or its Back does not always make its bar lay
    /// out again, so such a change asks these bars for one more pass.
    private static let bars = NSHashTable<UINavigationBar>.weakObjects()
    private static var passQueued = false

    static func note(_ bar: UINavigationBar) { if !bars.contains(bar) { bars.add(bar) } }

    fileprivate static func itemChanged(_ item: UINavigationItem) {
        guard standsIn else { return }
        queuePass()
    }

    /// The list's unread count changed (it is the title of the page under a chat): its bars fit Back again.
    static func backTitleChanged() {
        guard !DeviceWord.isMac else { return }
        queuePass()
    }

    private static func queuePass() {
        guard !passQueued else { return }
        passQueued = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                passQueued = false
                if Theme.isDesktop {
                    for bar in bars.allObjects where bar.window != nil { DesktopBars.apply(bar, desktop: true) }
                } else {
                    for bar in bars.allObjects where bar.window != nil { applyBacks(bar) }
                }
            }
        }
    }

    /// [mac] #104: every page's Back in `bar` in the iOS look on the Mac (its bar's layout calls this); on the iPhone
    /// and iPad, a count's fitted Back (2026-10-30).
    static func applyBacks(_ bar: UINavigationBar) {
        let items = bar.items ?? []
        for (index, item) in items.enumerated() {
            apply(item, under: index > 0 ? items[index - 1] : nil, in: bar, desktop: false)
        }
    }

    private static func make(for item: UINavigationItem, in bar: UINavigationBar, counted: Bool) -> UIBarButtonItem {
        let pop = UIAction(image: UIImage(systemName: "chevron.backward")) { [weak bar] _ in
            (bar?.delegate as? UINavigationController)?.popViewController(animated: true)
        }
        let back: UIBarButtonItem
        #if targetEnvironment(macCatalyst)
        back = UIBarButtonItem(customView: macBackButton(pop: pop))   // [mac] #104: the chevron and the parent's name
        #else
        back = counted ? UIBarButtonItem(customView: CountBackButton(pop: pop)) : UIBarButtonItem(primaryAction: pop)
        #endif
        back.hidesSharedBackground = true
        back.accessibilityIdentifier = "BackButton"
        objc_setAssociatedObject(back, markKey, true, .OBJC_ASSOCIATION_RETAIN)
        // Long press: the pages under this one, nearest first, as the system's history menu.
        let history = UIMenu(children: [UIDeferredMenuElement.uncached { [weak bar, weak item] completion in
            guard let bar, let item, let navigation = bar.delegate as? UINavigationController else { completion([]); return }
            let items = bar.items ?? []
            guard let index = items.firstIndex(where: { $0 === item }), index > 0 else { completion([]); return }
            let pages = navigation.viewControllers
            completion(items[..<index].enumerated().reversed().compactMap { offset, under -> UIAction? in
                guard offset < pages.count else { return nil }
                let page = pages[offset]
                let name = DesktopBack.name(of: under, page: page)
                return UIAction(title: name) { [weak navigation, weak page] _ in
                    guard let navigation, let page else { return }
                    navigation.popToViewController(page, animated: true)
                }
            })
        }])
        if let button = back.customView as? UIButton { button.menu = history } else { back.menu = history }
        return back
    }

    #if targetEnvironment(macCatalyst)
    private static let popActionID = UIAction.Identifier("hq.back.pop")

    /// [mac] #104: Back as a Mac toolbar's: a plain chevron and the name of the page it goes back to, no glass. A long
    /// name is cut, not the bar's title.
    /// [mac] Stress test 2026-10-28 #55 (round 6): in the label colour, glyph and words, as a Mac toolbar's back item. It
    /// took the bar's tint, and `DesktopBars.quietGlyph` gives every custom-view bar item the Desktop Look's grey
    /// (`label2`), so "‹ Settings" read as switched off. Its own foreground now, which no tint reaches.
    private static func macBackButton(pop: UIAction) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = HQPalette.label
        config.image = UIImage(systemName: "chevron.backward")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(font: HQFont.preferred(.body), scale: .medium)
        config.imagePadding = 4
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 4)
        config.titleLineBreakMode = .byTruncatingTail
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var copy = attributes
            copy.font = HQFont.preferred(.body)
            return copy
        }
        let button = UIButton(configuration: config)
        button.tintAdjustmentMode = .normal   // [mac] round 6: the dimmed mode it inherits drew "Settings" at a quarter opacity
        let action = UIAction(identifier: popActionID, handler: { [weak button] _ in
            guard let button else { return }
            button.sendAction(pop)
        })
        button.addAction(action, for: .primaryActionTriggered)
        button.widthAnchor.constraint(lessThanOrEqualToConstant: HQFont.scaled(240)).isActive = true
        return button
    }

    /// The Mac button's name and, when the page has its own `backAction`, that action in place of the pop.
    private static func refreshMac(_ button: UIButton, title: String?, own: UIAction?, ink: UIColor) {
        if button.configuration?.title != title {
            button.configuration?.title = title
            button.sizeToFit()
        }
        if button.configuration?.baseForegroundColor != ink { button.configuration?.baseForegroundColor = ink }
        guard let own else { return }
        let ownID = UIAction.Identifier("hq.back.own")
        if objc_getAssociatedObject(button, ownKey) as? UIAction !== own {
            objc_setAssociatedObject(button, ownKey, own, .OBJC_ASSOCIATION_RETAIN)
            button.removeAction(identifiedBy: popActionID, for: .primaryActionTriggered)
            button.removeAction(identifiedBy: ownID, for: .primaryActionTriggered)
            button.addAction(UIAction(identifier: ownID, handler: { [weak button] _ in
                guard let button else { return }
                button.sendAction(own)
            }), for: .primaryActionTriggered)
        }
    }
    #endif

    #if targetEnvironment(macCatalyst)
    /// [mac] Stress test 2026-10-28 round 8: Back in the Desktop Look is the page title's own colour, as drawn on the
    /// bar (the title's colour over the bar's background, so a translucent one reads the same on Back). Back measured
    /// pure white beside a title at 219, outshining it; it stays a label colour, not the grey of the bar's glyphs. Made
    /// again at each bar layout, so a light or dark switch or a new look follows.
    private static func titleInk(of item: UINavigationItem, in bar: UINavigationBar) -> UIColor {
        let appearance = item.standardAppearance ?? bar.standardAppearance
        let traits = bar.traitCollection
        let title = ((appearance.titleTextAttributes[.foregroundColor] as? UIColor) ?? HQPalette.label).resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard title.getRed(&r, green: &g, blue: &b, alpha: &a), a < 1,
              let ground = appearance.backgroundColor?.resolvedColor(with: traits) else { return title }
        var gr: CGFloat = 0, gg: CGFloat = 0, gb: CGFloat = 0, ga: CGFloat = 0
        guard ground.getRed(&gr, green: &gg, blue: &gb, alpha: &ga), ga > 0.99 else { return title }
        return UIColor(red: r * a + gr * (1 - a), green: g * a + gg * (1 - a), blue: b * a + gb * (1 - a), alpha: 1)
    }
    #endif

    /// A page's name as the system's Back and history menu say it: its own title, not the look's capitals.
    static func name(of item: UINavigationItem, page: UIViewController?) -> String {
        for candidate in [page?.title, item.title] { if let candidate, !candidate.isEmpty { return candidate } }
        return "Back"
    }

    /// The list's count as the title (as the system Back shows it) and the page's own `backAction` for a tap.
    private static func refresh(_ back: UIBarButtonItem, previous: UINavigationItem?, item: UINavigationItem, in bar: UINavigationBar) {
        let pages = (bar.delegate as? UINavigationController)?.viewControllers ?? []
        let under = previous.flatMap { previous in (bar.items ?? []).firstIndex { $0 === previous } }.flatMap { $0 < pages.count ? pages[$0] : nil }
        // [mac] Stress test 2026-10-28 #104: on the Mac Back names the page under it (a bare chevron said nothing).
        let title = previous?.backButtonTitle ?? (DeviceWord.isMac ? previous.map { name(of: $0, page: under) } : nil)
        if back.title != title { back.title = title }
        let label = title.map { "Back, \($0)" } ?? previous.map { name(of: $0, page: under) } ?? "Back"
        if back.accessibilityLabel != label { back.accessibilityLabel = label }
        #if targetEnvironment(macCatalyst)
        if let button = back.customView as? UIButton {
            button.accessibilityLabel = label
            refreshMac(button, title: title, own: objc_getAssociatedObject(item, ownKey) as? UIAction,
                       ink: Theme.isDesktop ? titleInk(of: item, in: bar) : HQPalette.label)
            return
        }
        #endif
        if let button = back.customView as? CountBackButton {
            button.accessibilityLabel = label
            button.update(count: title ?? "", own: objc_getAssociatedObject(item, ownKey) as? UIAction, flat: back.hidesSharedBackground)
            return
        }
        // UIKit keeps a copy of an action it is given, so the stand-in remembers which one it took.
        if let own = objc_getAssociatedObject(item, ownKey) as? UIAction, objc_getAssociatedObject(back, ownKey) as? UIAction !== own {
            objc_setAssociatedObject(back, ownKey, own, .OBJC_ASSOCIATION_RETAIN)
            back.primaryAction = own
            back.image = UIImage(systemName: "chevron.backward")   // an action brings its own (empty) image and title
            back.title = title
        }
    }

    // MARK: Swipe back

    /// A hidden system Back turns UIKit's edge swipe off; while a stand-in is up the stack's swipes ask this instead,
    /// and everything else still goes to UIKit's own delegate.
    private static func keepSwipe(_ bar: UINavigationBar) {
        guard let navigation = bar.delegate as? UINavigationController else { return }
        if objc_getAssociatedObject(navigation, swipeKey) != nil { return }
        let keeper = SwipeKeeper(navigation: navigation)
        objc_setAssociatedObject(navigation, swipeKey, keeper, .OBJC_ASSOCIATION_RETAIN)
        keeper.attach()
    }

    /// The look went off: every stack's swipes go back to UIKit's own delegate.
    static func releaseSwipes(in root: UIViewController?) {
        guard let root else { return }
        if let navigation = root as? UINavigationController, let keeper = objc_getAssociatedObject(navigation, swipeKey) as? SwipeKeeper {
            keeper.detach()
            objc_setAssociatedObject(navigation, swipeKey, nil, .OBJC_ASSOCIATION_RETAIN)
        }
        root.children.forEach { releaseSwipes(in: $0) }
        releaseSwipes(in: root.presentedViewController)
    }
}

/// A count's Back (2026-10-30): the chevron and the count 6 pt apart, 13 pt in from the glass's edges (the bar adds 4
/// to these 9), the system Back's glyph and type. "‹ 2" is 59 pt wide where the system's was 82. A tap pops (or runs
/// the page's own `backAction`); a long press lists the pages under it (`DesktopBack.make` gives it the menu).
final class CountBackButton: UIButton {
    private var pop: UIAction
    private var own: UIAction?

    init(pop: UIAction) {
        self.pop = pop
        super.init(frame: .zero)
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "chevron.backward")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body, scale: .large)
            .applying(UIImage.SymbolConfiguration(weight: .semibold))
        config.imagePadding = 6
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 9, bottom: 10, trailing: 9)   // the bar's 44 pt to tap
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var copy = attributes
            copy.font = HQFont.preferred(.body)
            return copy
        }
        config.baseForegroundColor = HQPalette.label
        configuration = config
        accessibilityIdentifier = "BackButton"
        addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.sendAction(self.own ?? self.pop)
        }, for: .primaryActionTriggered)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `flat`: the Desktop Look's (no glass), its chevron where the look's plain Back has it, 14 pt in.
    func update(count: String, own: UIAction?, flat: Bool) {
        self.own = own
        let leading: CGFloat = flat ? 14 : 9
        guard configuration?.title != count || configuration?.contentInsets.leading != leading else { return }
        configuration?.title = count
        configuration?.contentInsets.leading = leading
        // The look's bar tint drew the chevron white beside a lavender count (Midnight): in the look it is the count's
        // colour; on glass it follows the glass, as the system Back's does.
        let chevron = UIImage(systemName: "chevron.backward")
        configuration?.image = flat ? chevron?.withTintColor(HQPalette.label, renderingMode: .alwaysOriginal) : chevron
        invalidateIntrinsicContentSize()
        sizeToFit()
    }
}

/// Stands between a navigation controller's back swipes and UIKit's own delegate for them.
private final class SwipeKeeper: NSObject, UIGestureRecognizerDelegate {
    private weak var navigation: UINavigationController?
    private var originals: [(UIGestureRecognizer, UIGestureRecognizerDelegate?)] = []

    init(navigation: UINavigationController) { self.navigation = navigation }

    private var recognizers: [UIGestureRecognizer] {
        [navigation?.interactivePopGestureRecognizer, navigation?.interactiveContentPopGestureRecognizer].compactMap { $0 }
    }

    func attach() {
        for recognizer in recognizers {
            originals.append((recognizer, recognizer.delegate))
            recognizer.delegate = self
        }
    }

    func detach() {
        for (recognizer, delegate) in originals where recognizer.delegate === self { recognizer.delegate = delegate }
        originals = []
    }

    private func original(for recognizer: UIGestureRecognizer) -> UIGestureRecognizerDelegate? {
        originals.first { $0.0 === recognizer }?.1
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let navigation, let top = navigation.topViewController else { return false }
        // The page on top shows the look's stand-in: swipe back as the system Back would allow.
        if DesktopBack.standsIn, DesktopBack.standIn(of: top.navigationItem) != nil {   // [mac] #104: both looks
            return navigation.viewControllers.count > 1 && navigation.transitionCoordinator == nil
        }
        return original(for: recognizer)?.gestureRecognizerShouldBegin?(recognizer) ?? true
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        original(for: recognizer)?.gestureRecognizer?(recognizer, shouldReceive: touch) ?? true
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        original(for: recognizer)?.gestureRecognizer?(recognizer, shouldRecognizeSimultaneouslyWith: other) ?? false
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        original(for: recognizer)?.gestureRecognizer?(recognizer, shouldRequireFailureOf: other) ?? false
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        original(for: recognizer)?.gestureRecognizer?(recognizer, shouldBeRequiredToFailBy: other) ?? false
    }
}

extension UINavigationItem {
    // Each of these runs the original (the implementations were exchanged), then keeps the look's items flat.

    @objc dynamic func hqSetHidesBackButton(_ hides: Bool) {
        guard !DesktopBack.settingRaw, DesktopBack.standsIn || DesktopBack.standIn(of: self) != nil else { return hqSetHidesBackButton(hides) }
        DesktopBack.record(hides, on: self)
        DesktopBack.settingRaw = true
        hqSetHidesBackButton(DesktopBack.effective(hides, on: self))
        DesktopBack.settingRaw = false
        DesktopBack.itemChanged(self)
    }

    @objc dynamic func hqSetHidesBackButton(_ hides: Bool, animated: Bool) {
        guard !DesktopBack.settingRaw, DesktopBack.standsIn || DesktopBack.standIn(of: self) != nil else {
            return hqSetHidesBackButton(hides, animated: animated)
        }
        DesktopBack.record(hides, on: self)
        DesktopBack.settingRaw = true
        hqSetHidesBackButton(DesktopBack.effective(hides, on: self), animated: animated)
        DesktopBack.settingRaw = false
        DesktopBack.itemChanged(self)
    }

    // [mac] Mac polish #67: the items are flattened before they are placed too (`DesktopBars.prepare`).
    @objc dynamic func hqSetLeftItems(_ items: [UIBarButtonItem]?) {
        DesktopBars.prepare(items); hqSetLeftItems(items); hqFlattenIfDesktop()
    }
    @objc dynamic func hqSetRightItems(_ items: [UIBarButtonItem]?) {
        DesktopBars.prepare(items); hqSetRightItems(items); hqKeepClose(); hqFlattenIfDesktop()
    }
    @objc dynamic func hqSetLeftItem(_ item: UIBarButtonItem?) {
        DesktopBars.prepare(item.map { [$0] }); hqSetLeftItem(item); hqFlattenIfDesktop()
    }
    @objc dynamic func hqSetRightItem(_ item: UIBarButtonItem?) {
        DesktopBars.prepare(item.map { [$0] }); hqSetRightItem(item); hqKeepClose(); hqFlattenIfDesktop()
    }
    @objc dynamic func hqSetLeftItems(_ items: [UIBarButtonItem]?, animated: Bool) {
        DesktopBars.prepare(items); hqSetLeftItems(items, animated: animated); hqFlattenIfDesktop()
    }
    @objc dynamic func hqSetRightItems(_ items: [UIBarButtonItem]?, animated: Bool) {
        DesktopBars.prepare(items); hqSetRightItems(items, animated: animated); hqKeepClose(); hqFlattenIfDesktop()
    }

    /// [mac] Stress test 2026-10-28 #55: a sheet's lone Done stays the trailing-most item whatever the page sets.
    private func hqKeepClose() {
        #if targetEnvironment(macCatalyst)
        SheetClose.keepTrailing(self)
        #endif
    }

    private func hqFlattenIfDesktop() {
        guard Theme.isDesktop else { DesktopBars.flattenPlain(of: self); return }   // [mac] Mac polish #67
        DesktopBars.flattenButtons(of: self, desktop: true)
        DesktopBack.itemChanged(self)
    }
}
