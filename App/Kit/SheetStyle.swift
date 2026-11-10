// [m9/ipad] How a phone-shaped sheet (Bot Info, Settings, New Bot, Group Info, a Kanban task) is presented
// (docs/spec/3x-ipad.md §4.8, D6): in two panes the system's centred form sheet, so its rows keep a phone's width
// instead of stretching across the window (UX study #161); otherwise the page sheet with its detents, as on the phone.

import ObjectiveC
import SwiftUI
import UIKit

@MainActor enum SheetStyle {
    /// `presenter`: whoever presents the sheet (its window says the layout); nil reads the app's tabs.
    static func apply(_ navigation: UINavigationController, from presenter: UIViewController?,
                      detents: [UISheetPresentationController.Detent] = [.large()]) {
        navigation.modalPresentationStyle = twoPanes(presenter) ? .formSheet : .pageSheet
        navigation.sheetPresentationController?.detents = detents
        #if targetEnvironment(macCatalyst)
        // [mac] The form sheet keeps the iPad's 620 × 700 pt in any window, so a Kanban task or Bot Info scrolled with
        // most of the window empty. On the Mac it's as tall as the window allows, at the same width (owner 2026-10-23).
        if navigation.modalPresentationStyle == .formSheet, let window = presentingWindow(presenter) {
            let tall = max(700, min(window.bounds.height - 120, 1100))
            navigation.preferredContentSize = CGSize(width: 620, height: tall)
            MacSheetFit.attach(to: navigation, tall: tall)
        }
        #endif
    }

    /// [mac] A sheet that sizes itself with detents and no navigation controller (the Update Add-on and Update Hermes
    /// sheets): the Mac ignores detents, so it stayed the system's small form sheet and its steps scrolled, crammed
    /// (owner 2026-11-07). On the Mac it is the other sheets' size: 620 wide, as tall as the window allows.
    static func macTall(_ controller: UIViewController, from presenter: UIViewController?) {
        #if targetEnvironment(macCatalyst)
        guard let window = presentingWindow(presenter) else { return }
        controller.modalPresentationStyle = .formSheet
        controller.preferredContentSize = CGSize(width: 620, height: max(700, min(window.bounds.height - 120, 1100)))
        #endif
    }

    private static func twoPanes(_ presenter: UIViewController?) -> Bool {
        let tabs = presenter?.viewIfLoaded?.window.flatMap { AppRoot.tabs($0) } ?? MainTabController.current
        return tabs?.split?.isDouble == true
    }

    private static func presentingWindow(_ presenter: UIViewController?) -> UIWindow? {
        presenter?.viewIfLoaded?.window ?? MainTabController.current?.viewIfLoaded?.window
    }
}

#if targetEnvironment(macCatalyst)
/// [mac] Stress test 2026-10-28 #32: a short page (Usage & Limits, Model Prices, Changes, Commands) sat at the top of a
/// window-tall sheet. The sheet now follows its page's scrolling content, from 320 pt up to the tall size a long list
/// keeps. It waits for the content to settle (a page fills in after loading), then follows it (#80: it used to only
/// grow); while a field in it is being typed in it only grows. An empty page (its notice drawn over no rows) is 420.
@MainActor final class MacSheetFit: UIView {
    private static var key: UInt8 = 0
    private weak var navigation: UINavigationController?
    private weak var watched: UIScrollView?
    private var watch: NSKeyValueObservation?
    private var tall: CGFloat
    private var height: CGFloat = 0
    private var tries = 0
    private var settle: DispatchWorkItem?

    static func attach(to navigation: UINavigationController, tall: CGFloat) {
        let fit = MacSheetFit(navigation, tall: tall)
        objc_setAssociatedObject(navigation, &key, fit, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        fit.frame = navigation.view.bounds
        fit.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        navigation.view.addSubview(fit)   // its layout passes are the cue to look for the page's list
    }

    /// [mac-audit K] Owner 2026-11-02: a settings page in a sheet (Tool Calls: seven choices, most with a two-line
    /// description) followed its list to 920 pt, nearly the whole window, for a few switches. It stops at `height` and
    /// its list scrolls the rest, as a Mac preferences sheet does.
    static func cap(_ navigation: UINavigationController, at height: CGFloat) {
        guard let fit = objc_getAssociatedObject(navigation, &key) as? MacSheetFit, height < fit.tall else { return }
        fit.tall = height
        navigation.preferredContentSize.height = min(navigation.preferredContentSize.height, height)
    }

    private init(_ navigation: UINavigationController, tall: CGFloat) {
        self.navigation = navigation
        self.tall = tall
        super.init(frame: .zero)
        isHidden = true
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A notice put up or taken down (an empty answer, an error) can leave the list's content size as it was.
        if let watched { follow(watched); return }
        guard let page = navigation?.topViewController?.viewIfLoaded, let scroll = Self.list(in: page, depth: 0) else {
            // The page isn’t in place yet, or keeps no list of its own: a few more looks, then it stays tall.
            tries += 1
            if tries < 20 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.setNeedsLayout() } }
            return
        }
        watched = scroll
        watch = scroll.observe(\.contentSize, options: [.initial]) { [weak self] scroll, _ in
            MainActor.assumeIsolated { self?.follow(scroll) }
        }
    }

    /// The page's own list: the view itself, or the first tall scroll view a few levels in (a SwiftUI List's).
    /// [mac] Never the scroll view inside a page's notice (`UIContentUnavailableView`, Commands' "No Commands
    /// Available"): it fills the page to centre the notice, so a sheet following it stayed window-tall.
    private static func list(in view: UIView, depth: Int) -> UIScrollView? {
        if view is UIContentUnavailableView { return nil }
        if let scroll = view as? UIScrollView, scroll.bounds.height > 100, !(scroll is UITextView) { return scroll }
        guard depth < 6 else { return nil }
        for child in view.subviews where !child.isHidden {
            if let found = list(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private func follow(_ scroll: UIScrollView) {
        settle?.cancel()
        relax?.cancel()   // [mac] #74: the list moved again, so it isn't still yet
        let work = DispatchWorkItem { [weak self, weak scroll] in if let scroll { self?.fit(scroll) } }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// [mac] Stress test 2026-10-28 #74: how long the list must stay still while a field holds words before the sheet
    /// fits it again. Longer than the gap between keys, so it never moves per key.
    private static let typingPause: TimeInterval = 1.2
    private var relax: DispatchWorkItem?

    private func fit(_ scroll: UIScrollView, settled: Bool = false) {
        guard let navigation else { return }
        relax?.cancel()
        relax = nil
        let content = scroll.contentSize.height
        // [mac] A page showing its notice over no rows (Commands' "No Commands Available", an error) is the empty
        // page's 420, whatever the bare list's few points of padding add up to.
        let notice = navigation.topViewController?.contentUnavailableConfiguration != nil
        let wanted = content > 0 && !notice ? content + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom : 420
        // Stress test 2026-10-28 #71, #74, #80: only growing kept the height of whatever showed while the page loaded
        // (Commands' skeleton rows, Prices' "Looking up list prices…"), so a settled page sat over 60 to 190 pt of empty
        // sheet, a different amount in each look. Settled, the sheet now follows its page both ways; only while
        // something is typed in it (a search narrowing the list) does it keep its height, so it doesn't jump per key.
        // [mac] #74 (round 3): the fit only ran when the list's size changed, so once a search had narrowed Model
        // Prices to one row and the typing stopped, nothing fitted it again and the sheet kept the whole list's height
        // under that row for as long as the field held its words. Now a typing floor lasts until the list has been
        // still for `typingPause`, then the sheet fits the settled list.
        let typing = !settled && Self.typing(in: navigation.view, depth: 0)
        let floor = typing ? height : 0
        let next = min(tall, max(320, floor, wanted.rounded(.up)))
        let fitted = min(tall, max(320, wanted.rounded(.up)))
        if typing, abs(next - fitted) > 1 {   // held up by the floor: fit once the list is still
            let work = DispatchWorkItem { [weak self, weak scroll] in if let scroll { self?.fit(scroll, settled: true) } }
            relax = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.typingPause, execute: work)
        }
        guard abs(next - height) > 1 || height == 0 else { return }
        height = next
        // A page that asks for more width keeps it (the Table page: a wide table's own width, up to 900).
        let width = max(620, navigation.topViewController?.preferredContentSize.width ?? 0)
        navigation.preferredContentSize = CGSize(width: width, height: next)
    }

    /// A text field in the sheet has the keyboard (a search field, the Prompts editor's fields). [mac] A search field
    /// counts only with words in it, the only time it narrows the list: an empty one holding the keyboard kept the
    /// height a loading list had reached as the floor. [mac] #74 (round 3): Model Prices' field is a SwiftUI text field
    /// in the list (`PricesMacSearch`), a plain `UITextField`, so the words-only rule never reached it: merely clicked
    /// into, it held the floor. A one-line field now counts only with words in it too; a text view always does.
    private static func typing(in view: UIView, depth: Int) -> Bool {
        if view.isFirstResponder, view.window != nil {
            if let field = view as? UITextField { return !(field.text ?? "").isEmpty }
            if view is UITextView { return true }
        }
        guard depth < 12 else { return false }
        return view.subviews.contains { typing(in: $0, depth: depth + 1) }
    }
}
#endif

extension UIBarButtonItem {
    /// The item a sheet or viewer closes with. iPhone: the system's item (✕, Cancel, Done), as before. [mac] Stress test
    /// 2026-10-28 #55: on the Mac the system's items draw as a ✕ or ✓ in a circle, and sheets and viewers closed three
    /// ways (✕, a grey Done, a glass Done). Every one now ends in a word, Cancel for a form that throws away its edits and
    /// Done otherwise, in the label colour: the Desktop Look's grey bar tint made Done read as switched off.
    static func hqClose(_ item: SystemItem = .close, action: UIAction?) -> UIBarButtonItem {
        #if targetEnvironment(macCatalyst)
        // [mac] Stress test 2026-10-28 #55 (round 6): a titled bar item's words are drawn by the bar, which took their
        // colour from the bar's tint chain whatever the item said (round 2's title attributes kept their font, not their
        // colour: Done stayed mid-grey in both looks, luminance 93 against the title's 35). The word is now the item's
        // own button with its own foreground, which no tint reaches: the label colour, Done semibold as the Mac's default
        // button, Cancel regular, label 3 while switched off.
        let word = item == .cancel ? "Cancel" : "Done"
        let close = MacCloseItem(word: word, semibold: item != .cancel, action: action)
        close.title = word
        return close
        #else
        return UIBarButtonItem(systemItem: item, primaryAction: action)
        #endif
    }

    /// A sheet's bar item that is a plain word beside Done (Bot Info's Edit): the system's titled item. [mac] Mac polish
    /// #70: on the Mac drawn as Done is (`MacCloseItem`), in the label colour at Done's size, regular weight, label 3
    /// while switched off. The bar's tint drew it smaller and grey, so it read as switched off when it worked.
    static func hqWord(_ word: String, action: UIAction?) -> UIBarButtonItem {
        #if targetEnvironment(macCatalyst)
        let item = MacCloseItem(word: word, semibold: false, action: action)
        item.title = word
        return item
        #else
        return UIBarButtonItem(title: word, primaryAction: action)
        #endif
    }
}

#if targetEnvironment(macCatalyst)
/// [mac] Stress test 2026-10-28 #55 (round 6): a sheet's Done or Cancel as a plain button in the label colour (see
/// `hqClose`). Switching the item off switches its button off, as a titled item's words would grey.
final class MacCloseItem: UIBarButtonItem {
    /// The words' font: also the Find bar's Done (`ChatFindBar`), so every Done on the Mac is one size and weight.
    /// [mac] Stress test 2026-10-28 round 7: the sheet title's size (`MacType.pageTitle`), as a Mac sheet has, never
    /// larger. The Menus sheets' body font (`menusFont`) is scaled for a large text size of its own, so Done stood
    /// visibly bigger than the title beside it (Chat Info).
    static func font(semibold: Bool) -> UIFont {
        let title = MacType.pageTitle
        return semibold ? title : HQFont.face(ofSize: title.pointSize, weight: .regular)
    }

    convenience init(word: String, semibold: Bool, action: UIAction?) {
        var config = UIButton.Configuration.plain()
        config.title = word
        config.baseForegroundColor = HQPalette.label
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        let font = Self.font(semibold: semibold)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var copy = attributes
            copy.font = font
            return copy
        }
        let button = MacCloseButton(configuration: config)
        // [mac] Stress test 2026-10-28 round 6: a sheet's bar inherits the dimmed tint mode, and a configuration button
        // draws its title at about a quarter opacity there whatever its foreground (measured: label 255,255,255@0.25).
        // Pinned to normal, so Done reads as a live button.
        button.tintAdjustmentMode = .normal
        button.configurationUpdateHandler = { button in
            button.configuration?.baseForegroundColor = button.isEnabled ? HQPalette.label : HQPalette.label3
        }
        if let action { button.addAction(action, for: .primaryActionTriggered) }
        button.sizeToFit()
        self.init(customView: button)
    }

    override var isEnabled: Bool {
        didSet { (customView as? UIControl)?.isEnabled = isEnabled }
    }

    /// [mac] Stress test 2026-10-28 round 8: the sheet's title in the page-title token too. The Desktop Look's bars
    /// carry it, but the iOS look's sheets kept the system's title (13 pt cap height against Done's 15; "Chat Info" 73
    /// pt wide against 82). On the bar, the button puts the token on the sheet's bar and its page's own appearances.
    private final class MacCloseButton: UIButton {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil,
                  let bar = sequence(first: superview, next: { $0?.superview }).lazy.compactMap({ $0 as? UINavigationBar }).first
            else { return }
            // Mac polish #77: the subtitle's token with the title's (`MacWindow.tokened`).
            if let next = MacWindow.tokened(bar.standardAppearance) { bar.standardAppearance = next }
            if let next = MacWindow.tokened(bar.scrollEdgeAppearance) { bar.scrollEdgeAppearance = next }
            if let next = MacWindow.tokened(bar.compactAppearance) { bar.compactAppearance = next }
            for item in bar.items ?? [] { MacWindow.titleToken(item) }
        }
    }

    // The callers name the item ("sheet.close", "Close"); the button is what UI tests and VoiceOver find.
    override var accessibilityIdentifier: String? {
        didSet { customView?.accessibilityIdentifier = accessibilityIdentifier }
    }

    override var accessibilityLabel: String? {
        didSet { customView?.accessibilityLabel = accessibilityLabel }
    }
}
#endif

// MARK: - Where a lone Done sits

/// [mac] Stress test 2026-10-28 #55: a sheet or viewer that closes with a lone Done (no Save or Add beside it) has it on
/// the trailing edge on the Mac, as a Mac sheet's default button; the iPhone keeps it leading. Sheets set their own
/// trailing items after the frame puts Done there (Copy, Edit, ⋯, a browser's tabs), so the Mac's Done is parked on the
/// page's item: every setter of the trailing items (`DesktopBack`'s hooks) puts it back at the edge, and readers ask for
/// `hqOwnRightItem(s)`, the page's own items without it. A form (Cancel with Save or Add) keeps Cancel leading.
@MainActor enum SheetClose {
    private static let parkedKey = malloc(1)!

    static func parked(on item: UINavigationItem) -> UIBarButtonItem? {
        objc_getAssociatedObject(item, parkedKey) as? UIBarButtonItem
    }

    fileprivate static func park(_ close: UIBarButtonItem?, on item: UINavigationItem) {
        objc_setAssociatedObject(item, parkedKey, close, .OBJC_ASSOCIATION_RETAIN)
    }

    /// After the page's trailing items change: the parked Done goes back to the edge (index 0 is the trailing-most).
    static func keepTrailing(_ item: UINavigationItem) {
        guard let close = parked(on: item) else { return }
        let items = item.rightBarButtonItems ?? []
        guard items.first !== close else { return }
        item.rightBarButtonItems = [close] + items.filter { $0 !== close }   // re-enters the hook, then stops here
    }
}

extension UINavigationItem {
    /// Puts a sheet's lone Done: leading on the iPhone, [mac] trailing-most on the Mac (#55), kept there.
    func hqPlaceClose(_ close: UIBarButtonItem) {
        #if targetEnvironment(macCatalyst)
        // [mac] Stress test 2026-10-28 #55
        if let old = SheetClose.parked(on: self), old !== close {
            SheetClose.park(nil, on: self)
            rightBarButtonItems = (rightBarButtonItems ?? []).filter { $0 !== old }
        }
        if leftBarButtonItems?.contains(where: { $0 === close }) == true { leftBarButtonItem = nil }
        SheetClose.park(close, on: self)
        SheetClose.keepTrailing(self)
        #else
        leftBarButtonItem = close
        #endif
    }

    /// A form's own close (Cancel or a Done that tucks, beside Save or Add) on the leading edge, replacing the frame's
    /// lone Done wherever it was (`ChatSheet.wrap` parks one on the Mac).
    func hqPlaceFormClose(_ close: UIBarButtonItem) {
        hqRemoveClose()
        leftBarButtonItem = close
    }

    /// Takes the lone Done away (a page pushed inside another sheet goes Back instead), wherever it sits.
    func hqRemoveClose() {
        #if targetEnvironment(macCatalyst)
        // [mac] Stress test 2026-10-28 #55
        if let old = SheetClose.parked(on: self) {
            SheetClose.park(nil, on: self)
            rightBarButtonItems = (rightBarButtonItems ?? []).filter { $0 !== old }
            return
        }
        #endif
        leftBarButtonItem = nil
    }

    /// The page's own trailing items, without the Mac's parked Done (#55). The iPhone has none parked.
    var hqOwnRightItems: [UIBarButtonItem] {
        let close = SheetClose.parked(on: self)
        return (rightBarButtonItems ?? []).filter { $0 !== close }
    }

    /// The page's own trailing-most item (what `rightBarButtonItem` meant before the Mac's Done joined them).
    var hqOwnRightItem: UIBarButtonItem? { hqOwnRightItems.first }
}

extension UISheetPresentationController {
    /// A page that has to stay opaque at every height (Webhooks): a colour effect is the system's way to an opaque
    /// grouped page. [mac] Mac sheets are solid already (and the API isn't there).
    func hqOpaqueGroupedPage() {
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 26.1, *) { backgroundEffect = UIColorEffect(color: HQPalette.groupedPage) }
        #endif
    }

    /// [glass] Owner 2026-10-30 ("utilize more liquid glass, like in pop-ups"): a half-height sheet sits on the system's
    /// Liquid Glass over the chat, as iOS 26 draws it; it turns solid at full height by itself. What made these sheets
    /// opaque before (verification round 3: bubbles behind tinted the values) is handled in the page, not here: every
    /// line people read sits on a solid card (`hqGlassReady`), so only the bar and short section labels are on glass.
    /// The Desktop Look has no glass: there the sheet keeps the opaque grouped page, and turning the look on or off
    /// with the sheet open switches it (ThemeChrome.styleSheet).
    /// `everyHeight`: glass at full height too (New Job, owner 2026-10-31: "the entire pop-up should be liquid glass").
    /// iOS turns a full-height sheet solid by itself; this sheet asks for the glass as its own background instead.
    func hqGlassPage(everyHeight: Bool = false) {
        SheetGlass.install()
        objc_setAssociatedObject(self, SheetGlass.key, true, .OBJC_ASSOCIATION_RETAIN)
        if everyHeight { objc_setAssociatedObject(self, SheetGlass.everyHeightKey, true, .OBJC_ASSOCIATION_RETAIN) }
        SheetGlass.apply(self, desktop: Theme.isDesktop)
    }
}

/// [glass] True inside a sheet while it sits on glass: `HQPalette.sheetPage` turns clear and grouped SwiftUI lists drop
/// their page (`hqGroupedPage`), so the rows' solid cards float on the glass.
nonisolated struct GlassSheetTrait: UITraitDefinition {
    static let defaultValue = false
    static let affectsColorAppearance = true
    static let name = "HQGlassSheet"
}

/// [glass] The trait as SwiftUI sees it: `hqGroupedPage` drops a List's page and keeps its rows solid while it is true.
struct GlassSheetEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension GlassSheetEnvironmentKey: UITraitBridgedEnvironmentKey {
    static func read(from traitCollection: UITraitCollection) -> Bool { traitCollection[GlassSheetTrait.self] }
    static func write(to mutableTraits: inout UIMutableTraits, value: Bool) { mutableTraits[GlassSheetTrait.self] = value }
}

extension EnvironmentValues {
    var hqGlassSheet: Bool {
        get { self[GlassSheetEnvironmentKey.self] }
        set { self[GlassSheetEnvironmentKey.self] = newValue }
    }

    /// [tasks] A List drawn on a chat's page, above its messages (the task's details on the task's chat): no page of
    /// its own, and its cards take the chat's own card fill (`ChatBaseCell.contentCardFill`), as the chat's cards do.
    var hqChatLead: Bool {
        get { self[ChatLeadEnvironmentKey.self] }
        set { self[ChatLeadEnvironmentKey.self] = newValue }
    }
}

struct ChatLeadEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

/// [glass] Which sheets sit on glass in the iOS look, and the colour effect that replaces it in the Desktop Look.
@MainActor enum SheetGlass {
    static let key = malloc(1)!
    static let stashKey = malloc(1)!
    static let everyHeightKey = malloc(1)!
    private static var installed = false

    /// Hooks every sheet's layout once (the Desktop Look's own hook in DesktopEdges only exists while the look is on;
    /// both chain to the original whichever was installed first).
    static func install() {
        guard !installed else { return }
        installed = true
        let type: AnyClass = UISheetPresentationController.self
        let selector = #selector(UIPresentationController.containerViewDidLayoutSubviews)
        let hook = #selector(UISheetPresentationController.hqGlassContainerViewDidLayoutSubviews)
        guard let original = class_getInstanceMethod(type, selector), let replacement = class_getInstanceMethod(type, hook) else { return }
        if class_addMethod(type, selector, method_getImplementation(replacement), method_getTypeEncoding(replacement)) {
            class_replaceMethod(type, hook, method_getImplementation(original), method_getTypeEncoding(original))
        } else if let own = class_getInstanceMethod(type, selector) {
            method_exchangeImplementations(own, replacement)
        }
    }

    static func isGlassPage(_ sheet: UISheetPresentationController) -> Bool {
        objc_getAssociatedObject(sheet, key) != nil
    }

    /// A glass page that stays glass at full height (`hqGlassPage(everyHeight:)`).
    static func isGlassEveryHeight(_ sheet: UISheetPresentationController) -> Bool {
        objc_getAssociatedObject(sheet, everyHeightKey) != nil
    }

    /// [glass-design] A sheet that keeps its own page and background (How Voice Works) but carries `GlassSheetTrait`.
    private static let traitOnlyKey = malloc(1)!

    static func markTraitOnly(_ sheet: UISheetPresentationController) {
        objc_setAssociatedObject(sheet, traitOnlyKey, true, .OBJC_ASSOCIATION_RETAIN)
    }

    static func tracksGlass(_ sheet: UISheetPresentationController) -> Bool {
        isGlassPage(sheet) || objc_getAssociatedObject(sheet, traitOnlyKey) != nil
    }

    /// Look on: an opaque page (grouped for our glass pages, the plain page for any other sheet that would otherwise
    /// show the system's glass, e.g. How Voice Works). Look off: our glass pages go back to glass, any other sheet
    /// gets back exactly what it had.
    static func apply(_ sheet: UISheetPresentationController, desktop: Bool) {
        #if !targetEnvironment(macCatalyst)
        guard #available(iOS 26.1, *) else { return }
        let ours = isGlassPage(sheet)
        if desktop {
            if !ours, objc_getAssociatedObject(sheet, stashKey) == nil {
                objc_setAssociatedObject(sheet, stashKey, Box(sheet.backgroundEffect), .OBJC_ASSOCIATION_RETAIN)
            }
            if ours || sheet.backgroundEffect == nil {
                sheet.backgroundEffect = UIColorEffect(color: ours ? HQPalette.groupedPage : HQPalette.page)
            }
        } else if ours {
            sheet.backgroundEffect = nil
        } else if let stash = objc_getAssociatedObject(sheet, stashKey) as? Box {
            sheet.backgroundEffect = stash.effect
            objc_setAssociatedObject(sheet, stashKey, nil, .OBJC_ASSOCIATION_RETAIN)
        }
        #endif
        layout(sheet)
    }

    /// After every layout of the sheet (and every look change): the page is clear only while the glass is there. At
    /// full height iOS draws the sheet solid, and an iPad's form sheet is solid too; there the page takes its grouped
    /// colour back, so the cards never sit on a page of their own colour.
    static func layout(_ sheet: UISheetPresentationController) {
        guard tracksGlass(sheet) else { return }
        let page = sheet.presentedViewController
        var glass = !Theme.isDesktop && !DeviceWord.isMac && page.traitCollection.horizontalSizeClass == .compact
        if glass, !isGlassEveryHeight(sheet), let frame = sheet.presentedView?.frame, let container = sheet.containerView,
           container.bounds.height > 0 {
            // Below full height. [glass-design] Measured from the status bar, not as a fifth of the screen: How Voice
            // Works' fitted height starts at 17 % and is glass there (full height starts about 10 pt under the bar).
            glass = frame.minY > container.safeAreaInsets.top + 40
        }
        // Reading an override that was never set traps, so ask first.
        let now = page.traitOverrides.contains(GlassSheetTrait.self) && page.traitOverrides[GlassSheetTrait.self]
        if now != glass { page.traitOverrides[GlassSheetTrait.self] = glass }
        backdrop(sheet, shown: glass)
    }

    private static let backdropKey = malloc(1)!

    private static let clearedKey = malloc(1)!

    /// [glass] A sheet that is glass at every height (`hqGlassPage(everyHeight:)`): the real `UIGlassEffect`, behind
    /// everything on the sheet (its bar too), with the sheet's own corners. Hidden wherever the page is opaque (the
    /// Desktop Look, the iPad's form sheet).
    private static func backdrop(_ sheet: UISheetPresentationController, shown: Bool) {
        guard isGlassEveryHeight(sheet), let host = sheet.presentedViewController.viewIfLoaded else { return }
        // iOS turns a full-height sheet solid, and takes a glass effect there without drawing it (the page went clear
        // over the screen behind, at the presentation and the detent alike). So while this glass shows, the system's
        // background is clear; wherever it doesn't, the system's own (only on a change: setting detents lays out again).
        let cleared = objc_getAssociatedObject(sheet, clearedKey) as? Bool ?? false
        #if !targetEnvironment(macCatalyst)   // a detent's own background is iOS-only
        if #available(iOS 26.1, *), cleared != shown {
            objc_setAssociatedObject(sheet, clearedKey, shown, .OBJC_ASSOCIATION_RETAIN)
            for detent in sheet.detents { detent.backgroundEffect = shown ? UIColorEffect(color: .clear) : nil }
            sheet.detents = sheet.detents
        }
        #endif
        var glass = objc_getAssociatedObject(sheet, backdropKey) as? UIVisualEffectView
        if glass == nil, shown {
            let made = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
            made.frame = host.bounds
            made.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            made.cornerConfiguration = .uniformCorners(radius: .containerConcentric())
            made.isUserInteractionEnabled = false
            made.accessibilityElementsHidden = true
            host.insertSubview(made, at: 0)
            objc_setAssociatedObject(sheet, backdropKey, made, .OBJC_ASSOCIATION_RETAIN)
            glass = made
        }
        guard let glass else { return }
        if glass.isHidden == shown { glass.isHidden = !shown }
        if glass.superview === host, host.subviews.first !== glass { host.sendSubviewToBack(glass) }
    }

    private final class Box: NSObject {
        let effect: UIVisualEffect?
        init(_ effect: UIVisualEffect?) { self.effect = effect }
    }
}

extension UISheetPresentationController {
    @objc dynamic func hqGlassContainerViewDidLayoutSubviews() {
        hqGlassContainerViewDidLayoutSubviews()   // the original (the implementations were exchanged)
        SheetGlass.layout(self)
    }
}

extension UITableViewCell {
    /// [glass] Keeps a grouped row's card solid while its sheet sits on glass (`HQPalette.sheetCard`); a pressed or
    /// picked row keeps the system's highlight, and off the glass the row is exactly the table's default. [glass-design]
    /// Its section gets the cards' thin edge there (`GlassCardOutliner`).
    func hqSolidOnGlass() {
        configurationUpdateHandler = { cell, state in
            guard state.traitCollection[GlassSheetTrait.self] else { return }
            var background = cell.backgroundConfiguration ?? cell.defaultBackgroundConfiguration()
            background = background.updated(for: state)
            if !state.isHighlighted && !state.isSelected { background.backgroundColor = HQPalette.sheetCard }
            cell.backgroundConfiguration = background
            cell.hqEdgeOnGlass()
        }
        setNeedsUpdateConfiguration()
    }
}
