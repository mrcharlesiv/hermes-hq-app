// desktoplook2: bar buttons in the Desktop Look are the desktop's flat icon buttons, not iOS 26's glass capsules
// (phone-ui-desktop.css:183-191). `UIBarButtonItem.hidesSharedBackground` (public, iOS 26) takes the capsule away. The
// items a screen sets come and go, so the bar is checked each time it lays out (`UINavigationBar.layoutSubviews`,
// exchanged on UINavigationBar itself, installed the first time the look is turned on, as ThemeChrome's glass hook
// is). Only items this file changed are put back when the look goes off.
// desktoplook3: a bar does not always lay out again when a page sets its items (the Settings sheet's ✕ kept its glass),
// so the items are also flattened as they are set (`DesktopBack`'s UINavigationItem hooks).

import ObjectiveC
import UIKit

enum DesktopBars {
    private static var installed = false
    private static let flatKey = malloc(1)!

    static func install() {
        guard !installed else { return }
        installed = true
        DesktopBack.install()                          // [desktoplook3]
        DesktopEdges.install()                         // [desktop-glass-sweep]
        hookBars()
        exchange(UIBarButtonItem.self, #selector(setter: UIBarButtonItem.image), #selector(UIBarButtonItem.hqDesktopSetImage(_:)))
    }

    private static var barsHooked = false
    /// The bar's layout hook alone. [mac] Stress test 2026-10-28 #50: the Mac installs it at launch for the iOS look's
    /// plain items (`macPlain`), without the rest of the look's hooks (`DesktopEdges` turns itself on as it installs).
    static func hookBars() {
        guard !barsHooked else { return }
        barsHooked = true
        exchange(UINavigationBar.self, #selector(UIView.layoutSubviews), #selector(UINavigationBar.hqDesktopLayoutSubviews))
        #if targetEnvironment(macCatalyst)
        // [mac] Mac polish #67: a sheet's bottom toolbar too (the Table page's Share was a round glass bubble).
        exchange(UIToolbar.self, #selector(UIView.layoutSubviews), #selector(UIToolbar.hqDesktopLayoutSubviews))
        exchange(UIToolbar.self, #selector(setter: UIToolbar.items), #selector(UIToolbar.hqDesktopSetItems(_:)))
        exchange(UIToolbar.self, #selector(UIToolbar.setItems(_:animated:)), #selector(UIToolbar.hqDesktopSetItems(_:animated:)))
        #endif
    }

    private static func exchange(_ type: AnyClass, _ selector: Selector, _ hook: Selector) {
        guard let original = class_getInstanceMethod(type, selector), let replacement = class_getInstanceMethod(type, hook) else { return }
        if class_addMethod(type, selector, method_getImplementation(replacement), method_getTypeEncoding(replacement)) {
            class_replaceMethod(type, hook, method_getImplementation(original), method_getTypeEncoding(original))
        } else if let own = class_getInstanceMethod(type, selector) {
            method_exchangeImplementations(own, replacement)
        }
    }

    /// A screen set a new image on a bar item this file made smaller (Jobs' scope filter filling in): smaller again at
    /// once. Waiting for the bar's next layout left Bots' then plain Filter full size beside the smaller Search (owner
    /// 2026-10-24); a new image does not lay the bar out again.
    fileprivate static func imageSet(on button: UIBarButtonItem) {
        guard objc_getAssociatedObject(button, glyphKey) != nil else { return }
        quietGlyph(button, desktop: true, size: lastPointSize)
    }

    /// A window, or a page not in one (another tab: `ThemeChrome.restyle`).
    static func flatten(_ root: UIView, desktop: Bool) {
        if desktop { install() }
        DesktopSegments.setAppearance(desktop)
        visit(root, desktop: desktop)
        DesktopEdges.apply(in: root, desktop: desktop)     // [desktop-glass-sweep] no scroll edge blur
        if !desktop, !DeviceWord.isMac, let window = root as? UIWindow { DesktopBack.releaseSwipes(in: window.rootViewController) }   // [desktoplook3] ([mac] #104: the Mac's Back stands in in both looks)
    }

    private static func visit(_ view: UIView, desktop: Bool) {
        if let bar = view as? UINavigationBar { apply(bar, desktop: desktop) }
        if let control = view as? UISegmentedControl { DesktopSegments.apply(control, desktop: desktop) }
        for child in view.subviews { visit(child, desktop: desktop) }
    }

    static func apply(_ bar: UINavigationBar, desktop: Bool) {
        let items = bar.items ?? []
        for (index, item) in items.enumerated() {
            DesktopBack.apply(item, under: index > 0 ? items[index - 1] : nil, in: bar, desktop: desktop)   // [desktoplook3]
            flattenSearch(item, desktop: desktop)      // [desktoplook3]
            flattenButtons(of: item, desktop: desktop, traits: bar.traitCollection)
        }
    }

    /// The item's own bar buttons without their glass capsule (or with it again, for the ones this file changed).
    /// `traits` are the bar's; without them (an item not in a bar yet) the size the last bar used.
    static func flattenButtons(of item: UINavigationItem, desktop: Bool, traits: UITraitCollection? = nil) {
        if let traits { lastPointSize = pointSize(traits) }
        let size = lastPointSize
        for button in (item.leftBarButtonItems ?? []) + (item.rightBarButtonItems ?? []) {
            flattenBackground(of: button, desktop: desktop)
            quietGlyph(button, desktop: desktop, size: size)
        }
    }

    /// A prominent item (Save, Create, Add) keeps its capsule in the look, in the accent (the look's bar tint is grey):
    /// its title is white, so with the capsule gone it was white on the white bar (owner 2026-10-26: no Save on Edit
    /// Head once a change was made). Called again when an item turns prominent or plain (`setProminentEnabled`), which
    /// does not lay the bar out.
    static func flattenBackground(of button: UIBarButtonItem, desktop: Bool) {
        let ours = (objc_getAssociatedObject(button, flatKey) as? Bool) ?? false
        let prominent = button.style == .prominent
        let flat = (desktop || macPlain) && !prominent
        if flat, !button.hidesSharedBackground {
            button.hidesSharedBackground = true
            objc_setAssociatedObject(button, flatKey, true, .OBJC_ASSOCIATION_RETAIN)
        } else if !flat, ours {
            button.hidesSharedBackground = false
            objc_setAssociatedObject(button, flatKey, nil, .OBJC_ASSOCIATION_RETAIN)
        }
        let accented = objc_getAssociatedObject(button, accentKey) != nil
        if desktop, prominent, !accented, button.tintColor == nil {
            button.tintColor = HQPalette.tint
            objc_setAssociatedObject(button, accentKey, true, .OBJC_ASSOCIATION_RETAIN)
        } else if accented, !(desktop && prominent) {
            button.tintColor = nil
            objc_setAssociatedObject(button, accentKey, nil, .OBJC_ASSOCIATION_RETAIN)
        }
    }

    private static let accentKey = malloc(1)!

    /// [mac] Mac polish #67: the iOS look's items without their glass as soon as a page sets them (`DesktopBack`'s
    /// hooks), not only when the bar next lays out: after Read Replies Aloud the chat's ⋯ and Inspector sat in a white
    /// glass pill until something laid the bar out again.
    static func flattenPlain(of item: UINavigationItem) {
        guard macPlain else { return }
        for button in (item.leftBarButtonItems ?? []) + (item.rightBarButtonItems ?? []) {
            flattenBackground(of: button, desktop: false)
        }
    }

    /// [mac] Mac polish #67: the items a page or a toolbar is about to set, flattened before the bar places them, in
    /// both looks; a prominent one (Save, Copy as Text) keeps its capsule. Flattened just after, the Task Page's Reload
    /// and Share kept a shared grey pill in the Desktop Look.
    static func prepare(_ items: [UIBarButtonItem]?) {
        guard macPlain else { return }
        for button in items ?? [] { flattenBackground(of: button, desktop: Theme.isDesktop) }
    }

    /// [mac] Stress test 2026-10-28 #50: on the Mac the iOS look's bar buttons are plain toolbar glyphs too, not glass
    /// capsules and circles grouped differently on every tab (Bots one 3-button capsule, Jobs a pill and a capsule,
    /// More a circle). A prominent item (Save, Create) keeps its tinted capsule, as in the Desktop Look.
    static var macPlain: Bool { DeviceWord.isMac }

    /// [mac] Stress test 2026-10-28 #66: the magnifier moved from tab to tab (x 599 on Bots, Sessions and Jobs, 655 on
    /// Artifacts and More) because each page put its own items outside it. On the Mac a page's magnifier
    /// (`PageBarCapsule.searchItem`, "<page>.search") is the trailing-most item, so it sits in the same place on every
    /// tab, as a Mac toolbar's search does; the page's other items keep their order inside it. Put right after the
    /// bar's layout, so it is never set while the bar lays out.
    /// [mac] Stress test 2026-10-28 #55: a sheet's parked Done (`SheetClose`) stays outside the magnifier.
    static func searchToEdge(_ item: UINavigationItem) {
        let items = item.rightBarButtonItems ?? []
        guard let index = items.firstIndex(where: { $0.accessibilityIdentifier?.hasSuffix(".search") == true }),
              index > searchEdge(items, item) else { return }
        DispatchQueue.main.async { [weak item] in
            guard let item, var now = item.rightBarButtonItems,
                  let at = now.firstIndex(where: { $0.accessibilityIdentifier?.hasSuffix(".search") == true }) else { return }
            let edge = searchEdge(now, item)
            guard at > edge else { return }
            now.insert(now.remove(at: at), at: edge)
            item.rightBarButtonItems = now
        }
    }

    private static func searchEdge(_ items: [UIBarButtonItem], _ item: UINavigationItem) -> Int {
        guard let close = SheetClose.parked(on: item), items.first === close else { return 0 }
        return 1
    }

    private static let glyphKey = malloc(1)!
    private static let quietKey = malloc(1)!
    private static let customTintKey = malloc(1)!
    private static let customSymbolKey = malloc(1)!
    private static let quietSizeKey = malloc(1)!

    /// The glyph of a plain icon item: iOS 26 draws bar items in the full label colour whatever the bar's tint, so in
    /// the look they outweighed the small grey title (UX study #124). Here the item takes the bar's `label2` itself, at
    /// the look's smaller size. An item with its own tint, a prominent one or a custom view is left alone; the look
    /// going off puts back what this changed. The smaller image is kept too, so an image the screen sets later (the
    /// Filter button turning filled) is noticed: it becomes the new original and is made smaller in turn, and the look
    /// going off leaves the screen's own image in place.
    /// The size follows the text size (`pointSize(_:)`), so a new text size makes it again from the original.
    private static func quietGlyph(_ button: UIBarButtonItem, desktop: Bool, size: CGFloat) {
        if let custom = button.customView as? UIButton { quietGlyph(custom, desktop: desktop, size: size); return }
        let original = objc_getAssociatedObject(button, glyphKey) as? UIImage
        let quieted = objc_getAssociatedObject(button, quietKey) as? UIImage
        if desktop {
            let resize = original != nil && button.image === quieted
            if resize, objc_getAssociatedObject(button, quietSizeKey) as? CGFloat == size { return }
            guard let image = resize ? original : button.image, image.isSymbolImage, button.style != .prominent,
                  button.customView == nil, original != nil || button.tintColor == nil else { return }
            let small = image.applyingSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: size, weight: glyphWeight(button)))
            objc_setAssociatedObject(button, glyphKey, image, .OBJC_ASSOCIATION_RETAIN)
            objc_setAssociatedObject(button, quietKey, small, .OBJC_ASSOCIATION_RETAIN)
            objc_setAssociatedObject(button, quietSizeKey, size, .OBJC_ASSOCIATION_RETAIN)
            button.image = small
            button.tintColor = HQPalette.label2
        } else if let original {
            // Forgotten first, so putting the image back is not taken for a screen's new image (`imageSet(on:)`).
            objc_setAssociatedObject(button, glyphKey, nil, .OBJC_ASSOCIATION_RETAIN)
            objc_setAssociatedObject(button, quietKey, nil, .OBJC_ASSOCIATION_RETAIN)
            objc_setAssociatedObject(button, quietSizeKey, nil, .OBJC_ASSOCIATION_RETAIN)
            if button.image === quieted { button.image = original }
            button.tintColor = nil
        }
    }

    /// A bar button drawn as its own UIButton (the Bots and Sessions Filter, whose menu stays live): the same grey,
    /// smaller glyph as the plain items beside it. Its symbol configuration holds for an image set later (the filled Filter);
    /// the look going off puts back its own tint and size.
    /// The plain items' 15 pt regular image still gets the bar's large scale on top (the bar's own configuration, see
    /// `PageBarCapsule.barGlyph`), so the button asks for that scale too: without it Sessions' Filter drew a size smaller
    /// than Bots' (owner 2026-10-24).
    private static func quietGlyph(_ custom: UIButton, desktop: Bool, size: CGFloat) {
        let stashed = objc_getAssociatedObject(custom, customTintKey) as? UIColor
        if desktop {
            if stashed == nil {
                objc_setAssociatedObject(custom, customTintKey, custom.tintColor, .OBJC_ASSOCIATION_RETAIN)
                objc_setAssociatedObject(custom, customSymbolKey, custom.preferredSymbolConfigurationForImage(in: .normal),
                                         .OBJC_ASSOCIATION_RETAIN)
            }
            custom.tintColor = HQPalette.label2
            custom.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: size, weight: macThinStep(.regular), scale: .large),
                                                   forImageIn: .normal)
        } else if let stashed {
            custom.tintColor = stashed
            custom.setPreferredSymbolConfiguration(objc_getAssociatedObject(custom, customSymbolKey) as? UIImage.SymbolConfiguration,
                                                   forImageIn: .normal)
            objc_setAssociatedObject(custom, customTintKey, nil, .OBJC_ASSOCIATION_RETAIN)
            objc_setAssociatedObject(custom, customSymbolKey, nil, .OBJC_ASSOCIATION_RETAIN)
        }
    }

    // MARK: [mac] Stress test 2026-10-28 #58: thin glyphs

    private static let thinKey = malloc(1)!

    /// [mac] #58: the Filter's three lines and Jobs' + are drawn with hairline strokes, so at the magnifier's and the
    /// compose glyph's weight they read lighter than them (both looks). On the Mac such an item's glyph is one weight
    /// step heavier, so the bar's glyphs read as one weight. Marked by the page (`markThin`); elsewhere nothing changes.
    static func markThin(_ item: UIBarButtonItem) {
        objc_setAssociatedObject(item, thinKey, true, .OBJC_ASSOCIATION_RETAIN)
        #if targetEnvironment(macCatalyst)
        if !Theme.isDesktop, let image = item.image, image.isSymbolImage {
            item.image = image.applyingSymbolConfiguration(UIImage.SymbolConfiguration(weight: macThinStep(.medium)))
        }
        #endif
    }

    private static func glyphWeight(_ button: UIBarButtonItem) -> UIImage.SymbolWeight {
        objc_getAssociatedObject(button, thinKey) != nil ? macThinStep(.regular) : .regular
    }

    /// One step heavier on the Mac (regular → medium, medium → semibold); `weight` elsewhere.
    static func macThinStep(_ weight: UIImage.SymbolWeight) -> UIImage.SymbolWeight {
        guard DeviceWord.isMac else { return weight }
        return weight == .regular ? .medium : weight == .medium ? .semibold : weight
    }

    /// The look's bar glyph: a little under the tab bar's 17 pt (`TabIcons.pointSize`), at the default text size.
    static let glyphSize: CGFloat = 15

    /// `glyphSize` at the text size the person picked: it grows with the bar's title, as the iOS look's glyphs do
    /// (`PageBarCapsule.barGlyph`, a body text style).
    static func pointSize(_ traits: UITraitCollection) -> CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(for: glyphSize, compatibleWith: traits).rounded()
    }

    /// The size the last bar laid out with, for an item given a new image or set before it is in a bar.
    private(set) static var lastPointSize: CGFloat = glyphSize
}

// MARK: [desktoplook3] The back button and the search field, without glass

extension DesktopBars {
    private static let searchKey = malloc(1)!

    /// A page's search field: never iOS 26's floating glass field at the foot of the screen (Settings) but a field
    /// in the bar (`searchBarPlacementAllowsToolbarIntegration`, public, iOS 26), drawn as the desktop's outlined box.
    static func flattenSearch(_ item: UINavigationItem, desktop: Bool) {
        let stashed = objc_getAssociatedObject(item, searchKey) as? NSNumber
        guard let search = item.searchController else {
            if !desktop, stashed != nil { objc_setAssociatedObject(item, searchKey, nil, .OBJC_ASSOCIATION_RETAIN) }
            return
        }
        if desktop {
            if stashed == nil {
                objc_setAssociatedObject(item, searchKey, NSNumber(value: item.searchBarPlacementAllowsToolbarIntegration), .OBJC_ASSOCIATION_RETAIN)
            }
            if item.searchBarPlacementAllowsToolbarIntegration { item.searchBarPlacementAllowsToolbarIntegration = false }
            // [mac] Mac polish #102: a field in the bar itself (Marketplace, Apps) stands on the bar's own grey pill,
            // whose ends stuck out round the look's square box: two shapes. There the pill alone; a field under the
            // title keeps the box.
            DesktopSearch.apply(search.searchBar, desktop: !(DeviceWord.isMac && item.searchBarPlacement != .stacked))
        } else if let stashed {
            if item.searchBarPlacementAllowsToolbarIntegration != stashed.boolValue {
                item.searchBarPlacementAllowsToolbarIntegration = stashed.boolValue
            }
            DesktopSearch.apply(search.searchBar, desktop: false)
            objc_setAssociatedObject(item, searchKey, nil, .OBJC_ASSOCIATION_RETAIN)
        }
    }
}

/// The desktop's search field: a 4 pt outlined box on the editor surface (the text field's own public colour and
/// layer). Nothing in the app styles a search field itself, so the look going off clears them.
@MainActor enum DesktopSearch {
    private static let doneKey = malloc(1)!

    static func apply(_ bar: UISearchBar, desktop: Bool) {
        let field = bar.searchTextField
        // The field's own border style, kept while the look draws the box.
        let saved = objc_getAssociatedObject(bar, doneKey) as? NSNumber
        if desktop {
            if saved == nil { objc_setAssociatedObject(bar, doneKey, NSNumber(value: field.borderStyle.rawValue), .OBJC_ASSOCIATION_RETAIN) }
            field.backgroundColor = ChatPalette.editor
            field.layer.cornerRadius = DesktopRows.radius
            field.layer.borderWidth = 1
            field.layer.borderColor = ChatPalette.strokeSecondary.resolvedColor(with: bar.traitCollection).cgColor
            field.layer.cornerCurve = .continuous
            field.borderStyle = .none
            field.clipsToBounds = true
        } else if let saved {
            field.borderStyle = UITextField.BorderStyle(rawValue: saved.intValue) ?? .roundedRect
            field.backgroundColor = nil
            field.layer.cornerRadius = 0
            field.layer.borderWidth = 0
            field.layer.borderColor = nil
            field.layer.cornerCurve = .circular
            field.clipsToBounds = false
            objc_setAssociatedObject(bar, doneKey, nil, .OBJC_ASSOCIATION_RETAIN)
        }
    }

    /// [mac-audit] Owner 2026-11-02 (round-4 #11): on the Mac a search field's placeholder is the look's label 2, not
    /// the system's faint placeholder grey (2.2:1 on the Desktop Look's field). Set again whenever its words change
    /// (a `placeholder` set afterwards goes back to the system's colour).
    static func fitPlaceholder(_ bar: UISearchBar) {
        guard DeviceWord.isMac, let words = bar.placeholder, !words.isEmpty else { return }
        let field = bar.searchTextField
        let ink = HQPalette.label2.resolvedColor(with: bar.traitCollection)
        if let shown = field.attributedPlaceholder, shown.string == words,
           (shown.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor) == ink { return }
        field.attributedPlaceholder = NSAttributedString(string: words, attributes: [.foregroundColor: ink])
    }
}

extension UINavigationBar {
    @objc dynamic func hqDesktopLayoutSubviews() {
        if DesktopBars.macPlain, let top = topItem { DesktopBars.searchToEdge(top) }   // [mac] stress test #66
        if DeviceWord.isMac, let bar = topItem?.searchController?.searchBar { DesktopSearch.fitPlaceholder(bar) }   // [mac-audit]
        if Theme.isDesktop {
            DesktopBack.note(self)                          // [desktoplook3]
            ThemeChrome.adoptLook(self)                     // [desktop-frost] never a bare bar
            DesktopBars.apply(self, desktop: true)
        } else if DesktopBars.macPlain {
            DesktopBack.note(self)                          // [mac] Stress test 2026-10-28 #104: the named plain Back
            DesktopBack.applyBacks(self)
            // [mac] Stress test 2026-10-28 #50: the iOS look's items without their glass, as they come and go.
            for item in items ?? [] {
                for button in (item.leftBarButtonItems ?? []) + (item.rightBarButtonItems ?? []) {
                    DesktopBars.flattenBackground(of: button, desktop: false)
                }
            }
        } else {
            DesktopBack.note(self)                          // 2026-10-30: a count's fitted Back in the iOS look
            DesktopBack.applyBacks(self)
        }
        hqDesktopLayoutSubviews()          // the original (the implementations were exchanged)
    }
}

#if targetEnvironment(macCatalyst)
extension UIToolbar {
    // Each runs the original (the implementations were exchanged): the items are flattened before they are placed, and
    // again as the toolbar lays out (an item that changed its style since).
    @objc dynamic func hqDesktopLayoutSubviews() {
        DesktopBars.prepare(items)
        hqDesktopLayoutSubviews()
    }

    @objc dynamic func hqDesktopSetItems(_ items: [UIBarButtonItem]?) {
        DesktopBars.prepare(items)
        hqDesktopSetItems(items)
    }

    @objc dynamic func hqDesktopSetItems(_ items: [UIBarButtonItem]?, animated: Bool) {
        DesktopBars.prepare(items)
        hqDesktopSetItems(items, animated: animated)
    }
}
#endif

extension UIBarButtonItem {
    @objc dynamic func hqDesktopSetImage(_ image: UIImage?) {
        hqDesktopSetImage(image)           // the original (the implementations were exchanged)
        if Theme.isDesktop { DesktopBars.imageSet(on: self) }
    }
}

/// Segmented controls in the look: the desktop's outlined strip (phone-ui-desktop.css, segmented): a 1 pt 4 pt-cornered
/// outline, 1 pt dividers, the chosen segment on the active-row fill. Public `UISegmentedControl` image API; the
/// appearance proxy covers controls made later, the window walk the ones on screen. Nothing in the app sets these
/// images itself, so the look going off clears them.
@MainActor enum DesktopSegments {
    static func setAppearance(_ desktop: Bool) {
        let proxy = UISegmentedControl.appearance()
        images(desktop).forEach { proxy.setBackgroundImage($0.image, for: $0.state, barMetrics: .default) }
        proxy.setDividerImage(desktop ? divider() : nil, forLeftSegmentState: .normal, rightSegmentState: .normal, barMetrics: .default)
        macTitles(proxy)
    }

    static func apply(_ control: UISegmentedControl, desktop: Bool) {
        images(desktop).forEach { control.setBackgroundImage($0.image, for: $0.state, barMetrics: .default) }
        control.setDividerImage(desktop ? divider() : nil, forLeftSegmentState: .normal, rightSegmentState: .normal, barMetrics: .default)
        macTitles(control)
    }

    /// [mac] The segments' own 13 pt titles carry no UI Scale, the Mac's text size: in either look they came out
    /// smaller than the rows under them (stress test 2026-10-28: Capabilities, Import Sessions, Command Center while it had tabs).
    static func macTitles(_ control: UISegmentedControl) {
        #if targetEnvironment(macCatalyst)
        for state in [UIControl.State.normal, .selected] {
            var attributes = control.titleTextAttributes(for: state) ?? [:]
            attributes[.font] = HQFont.system(ofSize: 13, weight: state == .selected ? .semibold : .regular)
            control.setTitleTextAttributes(attributes, for: state)
        }
        #else
        // [ui-sizing 2026-11-09] The iPhone and iPad too, now that UI Scale reaches the iOS look: at 150 % the segments
        // (Edit Bot's Head / Upload, Chat Bubbles' Style, Tasks' To Do / Ideas…) stayed 13 pt under 25 pt rows. At 100 %
        // in the iOS look iOS's own titles stay. A control that set a font of its own (Artifacts' filter) keeps it.
        let scaled = Theme.isDesktop || HQFont.scale != 1
        for state in [UIControl.State.normal, .selected] {
            var attributes = control.titleTextAttributes(for: state) ?? [:]
            let own = (attributes[.font] as? UIFont).map { !ScaledTitles.marked($0) } ?? false
            guard !own else { continue }
            attributes[.font] = scaled ? ScaledTitles.mark(HQFont.system(ofSize: 13, weight: state == .selected ? .semibold : .medium)) : nil
            control.setTitleTextAttributes(attributes, for: state)
        }
        #endif
    }

    /// [ui-sizing] The fonts `macTitles` set, told apart from a font a page gave its control.
    private enum ScaledTitles {
        nonisolated(unsafe) static var made: [UIFont] = []   // held, so an identity is never reused
        static func mark(_ font: UIFont) -> UIFont {
            if !made.contains(where: { $0 === font }) { made.append(font) }
            return font
        }
        static func marked(_ font: UIFont) -> Bool { made.contains { $0 === font } }
    }

    private static func images(_ desktop: Bool) -> [(image: UIImage?, state: UIControl.State)] {
        guard desktop else { return [(nil, .normal), (nil, .selected), (nil, .highlighted)] }
        return [(box(fill: .clear), .normal), (box(fill: HQPalette.cellPressed), .selected), (box(fill: HQPalette.cellPressed), .highlighted)]
    }

    /// A resizable outlined box, light and dark variants in one asset.
    static func box(fill: UIColor, height: CGFloat = 11) -> UIImage {
        dynamic { traits in
            let size = CGSize(width: 11, height: height)
            return UIGraphicsImageRenderer(size: size).image { _ in
                let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5), cornerRadius: DesktopRows.radius)
                fill.resolvedColor(with: traits).setFill(); path.fill()
                ChatPalette.strokeSecondary.resolvedColor(with: traits).setStroke(); path.lineWidth = 1; path.stroke()
            }.resizableImage(withCapInsets: UIEdgeInsets(top: 5, left: 5, bottom: 5, right: 5), resizingMode: .stretch)
        }
    }

    private static func divider() -> UIImage {
        dynamic { traits in
            UIGraphicsImageRenderer(size: CGSize(width: 1, height: 11)).image { context in
                ChatPalette.strokeSecondary.resolvedColor(with: traits).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 1, height: 11))
            }
        }
    }

    static func dynamic(_ draw: (UITraitCollection) -> UIImage) -> UIImage {
        let light = UITraitCollection(userInterfaceStyle: .light), dark = UITraitCollection(userInterfaceStyle: .dark)
        let asset = UIImageAsset()
        asset.register(draw(light), with: light)
        asset.register(draw(dark), with: dark)
        return asset.image(with: UITraitCollection.current)
    }
}
