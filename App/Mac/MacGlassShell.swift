#if targetEnvironment(macCatalyst)
import ObjectiveC
import UIKit

/// Unified frosted-glass outer window shell for the Mac app.
/// Bridges via ObjC runtime to the backing AppKit `NSWindow` to enable true behind-window
/// translucency (`NSVisualEffectView` with `.behindWindow` blending), window dragging from custom
/// chrome strips, and exact traffic-light geometry alignment.
@MainActor
enum MacGlassShell {
    /// Inset between the floating content canvas card and the window's trailing/bottom edges (app pts; ≈ 7.7 screen pts).
    static let canvasInset: CGFloat = 10
    /// Continuous corner radius of the floating content canvas card (app pts; ≈ 11.5 screen pts, concentric with macOS window corners).
    static let canvasCornerRadius: CGFloat = 15
    /// Height of the unified top chrome / workspace tab bar aligned dead-center with the traffic lights (app pts; ≈ 35.4 screen pts).
    static let topBarHeight: CGFloat = 46
    /// Leading clearance reserved for the native red/yellow/green traffic lights (app pts).
    static let trafficLightsClearance: CGFloat = 104

    private static var effectViewKey: UInt8 = 0
    private static var configuredKey: UInt8 = 0

    /// Applies behind-window vibrancy to the backing AppKit `NSWindow` of `window`, and synchronizes
    /// its appearance and Reduce Transparency state. Safe to call repeatedly on trait/theme changes.
    static func apply(to window: UIWindow?) {
        guard let window else { return }
        let reduced = HQAccessibility.reduceTransparency
        let dark = window.traitCollection.userInterfaceStyle == .dark

        window.isOpaque = reduced
        window.backgroundColor = reduced ? fallbackShellColor.resolvedColor(with: window.traitCollection) : .clear
        window.layer.isOpaque = reduced
        window.layer.backgroundColor = (reduced ? fallbackShellColor.resolvedColor(with: window.traitCollection) : UIColor.clear).cgColor

        guard let nsWindow = nsWindow(for: window) else {
            // The AppKit NSWindow attaches slightly after `willConnectTo`; retry shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak window] in
                guard let window else { return }
                Self.applyIfWindowPresent(window, attempt: 1)
            }
            return
        }
        configure(nsWindow: nsWindow, for: window, dark: dark, reduced: reduced)
    }

    private static func applyIfWindowPresent(_ window: UIWindow, attempt: Int) {
        guard window.windowScene != nil else { return }
        if let nsWindow = nsWindow(for: window) {
            configure(nsWindow: nsWindow, for: window, dark: window.traitCollection.userInterfaceStyle == .dark,
                      reduced: HQAccessibility.reduceTransparency)
            NotificationCenter.default.post(name: didAttachWindow, object: window)
        } else if attempt < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak window] in
                guard let window else { return }
                Self.applyIfWindowPresent(window, attempt: attempt + 1)
            }
        }
    }

    /// Posted once the backing `NSWindow` is located so chrome bars can snap to exact traffic-light coordinates.
    static let didAttachWindow = Notification.Name("hq.macGlassShell.didAttachWindow")

    /// Queries the exact vertical midpoint and trailing edge of the native macOS traffic-light buttons in `window` points.
    static func trafficLightsMetrics(in window: UIWindow?) -> (midY: CGFloat, maxX: CGFloat) {
        guard let window, let nsWindow = nsWindow(for: window),
              let frame = (nsWindow.value(forKey: "frame") as? NSValue)?.cgRectValue,
              frame.width > 0, window.bounds.width > 0 else {
            return (25, 92)
        }
        let buttonSel = NSSelectorFromString("standardWindowButton:")
        let convertSel = NSSelectorFromString("convertRect:toView:")
        guard nsWindow.responds(to: buttonSel) else { return (25, 92) }
        typealias ButtonFn = @convention(c) (NSObject, Selector, Int) -> NSObject?
        typealias ConvertFn = @convention(c) (NSObject, Selector, CGRect, NSObject?) -> CGRect
        let getButton = unsafeBitCast(nsWindow.method(for: buttonSel), to: ButtonFn.self)
        let scale = window.bounds.width / frame.width
        var midYs: [CGFloat] = []
        var maxX: CGFloat = 0
        for kind in 0...2 {
            guard let btn = getButton(nsWindow, buttonSel, kind),
                  btn.responds(to: convertSel),
                  let local = (btn.value(forKey: "bounds") as? NSValue)?.cgRectValue else { continue }
            let rect = unsafeBitCast(btn.method(for: convertSel), to: ConvertFn.self)(btn, convertSel, local, nil)
            let top = (frame.height - rect.maxY) * scale
            let height = rect.height * scale
            midYs.append(top + height / 2)
            maxX = max(maxX, rect.maxX * scale)
        }
        guard !midYs.isEmpty else { return (25, 92) }
        let avgMidY = midYs.reduce(0, +) / CGFloat(midYs.count)
        return (avgMidY, max(84, maxX))
    }

    /// Starts a native macOS window drag using AppKit's `performWindowDragWithEvent:` and the current mouse event.
    static func beginWindowDrag(for window: UIWindow?) {
        guard let window, let nsWindow = nsWindow(for: window),
              let appClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = appClass.value(forKey: "sharedApplication") as? NSObject,
              let event = app.value(forKey: "currentEvent") as? NSObject else { return }
        let sel = NSSelectorFromString("performWindowDragWithEvent:")
        guard nsWindow.responds(to: sel) else { return }
        _ = nsWindow.perform(sel, with: event)
    }

    /// Soft neutral fallback color when Reduce Transparency is active (or during offscreen UIKit-only snapshots).
    static let fallbackShellColor = UIColor { @Sendable traits in
        let dark = traits.userInterfaceStyle == .dark
        let set = ThemeTable.set(generation: traits[ThemeGenerationTrait.self])
        if set.groupedPageIsSystem {
            return dark ? UIColor(red: 0.10, green: 0.105, blue: 0.12, alpha: 1)
                        : UIColor(red: 0.915, green: 0.922, blue: 0.938, alpha: 1)
        }
        // Tinted gently toward colored skin's page color.
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        HQPalette.page.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        let delta: CGFloat = dark ? -0.04 : -0.055
        return UIColor(red: min(max(r + delta, 0), 1), green: min(max(g + delta, 0), 1), blue: min(max(b + delta, 0), 1), alpha: 1)
    }

    /// Subtle translucent tint over the live behind-window vibrancy so the sidebar and top bar stay cohesive with
    /// the floating content canvas while letting the desktop wallpaper bloom cleanly through the frosted shell.
    static let glassVeilColor = UIColor { @Sendable traits in
        let dark = traits.userInterfaceStyle == .dark
        let set = ThemeTable.set(generation: traits[ThemeGenerationTrait.self])
        if set.groupedPageIsSystem {
            // Light: luminous airy veil so the frosted shell stays close in brightness to the white card (never muddy grey).
            // Dark: deep smoked obsidian veil so the shell sits slightly deeper than the elevated dark glass canvas.
            return dark ? UIColor(red: 0.052, green: 0.058, blue: 0.076, alpha: 0.58)
                        : UIColor(red: 0.985, green: 0.988, blue: 0.994, alpha: 0.44)
        }
        let page = HQPalette.page.resolvedColor(with: traits)
        if dark {
            return adjusted(page, delta: -0.025).withAlphaComponent(0.60)
        }
        return page.withAlphaComponent(0.46)
    }

    /// Opaque base tone of the floating content canvas (used by `canvasSurfaceColor` and scrolled header frosts
    /// so scrolled bars match the lifted dark canvas tone instead of dropping back to darker raw `HQPalette.page`).
    static let canvasBaseColor = UIColor { @Sendable traits in
        let dark = traits.userInterfaceStyle == .dark
        let set = ThemeTable.set(generation: traits[ThemeGenerationTrait.self])
        let page = HQPalette.page.resolvedColor(with: traits)
        if set.groupedPageIsSystem {
            if dark {
                let lift: CGFloat = set.state.desktopLook ? 0.028 : 0.052
                return adjusted(page, delta: lift)
            }
            return .white
        }
        return dark ? adjusted(page, delta: 0.026) : page
    }

    /// Unified translucent surface for the floating content canvas (`RootSplitController.macCanvas`).
    /// Lets a whisper of the behind-window frosted glass continue across the main workspace (~13–18% live ambient
    /// tint) so the sidebar and content pane feel cut from the same window while preserving razor-sharp legibility.
    static let canvasSurfaceColor = UIColor { @Sendable traits in
        if HQAccessibility.reduceTransparency {
            return HQPalette.page.resolvedColor(with: traits)
        }
        let dark = traits.userInterfaceStyle == .dark
        let set = ThemeTable.set(generation: traits[ThemeGenerationTrait.self])
        let base = canvasBaseColor.resolvedColor(with: traits)
        if set.groupedPageIsSystem {
            return base.withAlphaComponent(dark ? 0.76 : 0.74)
        }
        return base.withAlphaComponent(dark ? 0.78 : 0.76)
    }

    /// Frosted header veil matching `canvasBaseColor` when scrolled content passes under the chat bar.
    static let canvasBarVeilColor = UIColor { @Sendable traits in
        let base = HQAccessibility.reduceTransparency
            ? HQPalette.page.resolvedColor(with: traits)
            : canvasBaseColor.resolvedColor(with: traits)
        return base.withAlphaComponent(HQAccessibility.reduceTransparency ? 1.0 : 0.90)
    }

    /// Whisper-thin glass seam separating the floating canvas from the outer frosted shell.
    static let canvasBorderColor = UIColor { @Sendable traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.085)
            : UIColor(white: 0, alpha: 0.052)
    }

    private static func adjusted(_ color: UIColor, delta: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return color }
        return UIColor(red: min(max(r + delta, 0), 1),
                       green: min(max(g + delta, 0), 1),
                       blue: min(max(b + delta, 0), 1),
                       alpha: a)
    }

    // MARK: - AppKit Bridge

    private static func configure(nsWindow: NSObject, for uiWindow: UIWindow, dark: Bool, reduced: Bool) {
        // 1. Window transparency & transparent titlebar.
        setBool(nsWindow, selector: "setOpaque:", value: reduced)
        setBool(nsWindow, selector: "setTitlebarAppearsTransparent:", value: true)
        if let nsColorClass = NSClassFromString("NSColor") as? NSObject.Type,
           let clearColor = nsColorClass.perform(NSSelectorFromString("clearColor"))?.takeUnretainedValue() as? NSObject {
            let bgSel = NSSelectorFromString("setBackgroundColor:")
            if nsWindow.responds(to: bgSel) { _ = nsWindow.perform(bgSel, with: clearColor) }
        }

        // 2. Match AppKit NSAppearance to UIKit's active userInterfaceStyle so behind-window vibrancy follows Light/Dark overrides.
        if let appearanceClass = NSClassFromString("NSAppearance") as? NSObject.Type {
            let namedSel = NSSelectorFromString("appearanceNamed:")
            if appearanceClass.responds(to: namedSel) {
                let name = (dark ? "NSAppearanceNameDarkAqua" : "NSAppearanceNameAqua") as NSString
                if let appearance = appearanceClass.perform(namedSel, with: name)?.takeUnretainedValue() as? NSObject {
                    let setAppSel = NSSelectorFromString("setAppearance:")
                    if nsWindow.responds(to: setAppSel) { _ = nsWindow.perform(setAppSel, with: appearance) }
                }
            }
        }

        // 3. Install or update the behind-window NSVisualEffectView inside NSWindow.contentView.
        guard let contentView = nsWindow.value(forKey: "contentView") as? NSObject else { return }
        let effectView = existingOrNewEffectView(in: contentView, for: uiWindow)
        if let effectView {
            // NSVisualEffectBlendingModeBehindWindow = 0
            setInt(effectView, selector: "setBlendingMode:", value: 0)
            // Light: NSVisualEffectMaterialSidebar (7) for airy luminous vibrancy.
            // Dark: NSVisualEffectMaterialUnderWindowBackground (18) for deep smoked glass without grey washout.
            setInt(effectView, selector: "setMaterial:", value: dark ? 18 : 7)
            // NSVisualEffectStateActive = 1 (or Inactive = 2 when Reduce Transparency is on)
            setInt(effectView, selector: "setState:", value: reduced ? 2 : 1)
            setBool(effectView, selector: "setHidden:", value: reduced)
        }

        // 4. Ensure Catalyst's hosting layer doesn't paint an opaque background over the NSVisualEffectView.
        clearHostingBackgrounds(in: contentView, excluding: effectView)

        if objc_getAssociatedObject(uiWindow, &configuredKey) == nil {
            objc_setAssociatedObject(uiWindow, &configuredKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            let subviewNames = ((contentView.value(forKey: "subviews") as? [NSObject]) ?? []).map { NSStringFromClass(type(of: $0)) }
            AppLog.note("mac", "glass shell attached to NSWindow (dark=\(dark), reduced=\(reduced), subviews=\(subviewNames.joined(separator: ",")))")
        }
    }

    private static func existingOrNewEffectView(in contentView: NSObject, for uiWindow: UIWindow) -> NSObject? {
        if let existing = objc_getAssociatedObject(uiWindow, &effectViewKey) as? NSObject {
            if let bounds = (contentView.value(forKey: "bounds") as? NSValue)?.cgRectValue {
                setRect(existing, selector: "setFrame:", value: bounds)
            }
            return existing
        }
        guard let effectClass = NSClassFromString("NSVisualEffectView") as? NSObject.Type else { return nil }
        let bounds = (contentView.value(forKey: "bounds") as? NSValue)?.cgRectValue ?? .zero
        let allocSel = NSSelectorFromString("alloc")
        let initSel = NSSelectorFromString("initWithFrame:")
        guard let initMethod = class_getInstanceMethod(effectClass, initSel),
              let allocated = (effectClass as AnyObject).perform(allocSel)?.takeUnretainedValue() else { return nil }
        typealias InitFrameFn = @convention(c) (AnyObject, Selector, CGRect) -> Unmanaged<AnyObject>?
        let initFn = unsafeBitCast(method_getImplementation(initMethod), to: InitFrameFn.self)
        guard let view = initFn(allocated, initSel, bounds)?.takeRetainedValue() as? NSObject else { return nil }
        // NSViewWidthSizable (2) | NSViewHeightSizable (16) = 18
        setUInt(view, selector: "setAutoresizingMask:", value: 18)
        setBool(view, selector: "setWantsLayer:", value: true)

        let subviews = (contentView.value(forKey: "subviews") as? [NSObject]) ?? []
        let addPosSel = NSSelectorFromString("addSubview:positioned:relativeTo:")
        if let first = subviews.first, contentView.responds(to: addPosSel) {
            typealias AddPosFn = @convention(c) (NSObject, Selector, NSObject, Int, NSObject?) -> Void
            // NSWindowBelow = -1
            unsafeBitCast(contentView.method(for: addPosSel), to: AddPosFn.self)(contentView, addPosSel, view, -1, first)
        } else {
            let addSel = NSSelectorFromString("addSubview:")
            if contentView.responds(to: addSel) { _ = contentView.perform(addSel, with: view) }
        }
        objc_setAssociatedObject(uiWindow, &effectViewKey, view, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return view
    }

    private static func clearHostingBackgrounds(in view: NSObject, excluding effectView: NSObject?, depth: Int = 0) {
        guard depth < 4 else { return }
        if view === effectView { return }
        if let layer = view.value(forKey: "layer") as? CALayer {
            layer.isOpaque = false
            layer.backgroundColor = nil
        }
        guard let subviews = view.value(forKey: "subviews") as? [NSObject] else { return }
        for sub in subviews where sub !== effectView {
            let cls = NSStringFromClass(type(of: sub))
            if cls.contains("UINS") || cls.contains("Scene") || cls.contains("Catalyst") || cls.contains("Hosting") {
                clearHostingBackgrounds(in: sub, excluding: effectView, depth: depth + 1)
            }
        }
    }

    static func nsWindow(for window: UIWindow) -> NSObject? {
        guard let appClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = appClass.value(forKey: "sharedApplication") as? NSObject,
              let windows = app.value(forKey: "windows") as? [NSObject] else { return nil }
        let uiWindowsSel = NSSelectorFromString("uiWindows")
        return windows.first {
            $0.responds(to: uiWindowsSel) && (($0.value(forKey: "uiWindows") as? [UIWindow])?.contains { $0 === window } ?? false)
        }
    }

    private static func setBool(_ target: NSObject, selector: String, value: Bool) {
        let sel = NSSelectorFromString(selector)
        guard target.responds(to: sel) else { return }
        typealias Fn = @convention(c) (NSObject, Selector, Bool) -> Void
        unsafeBitCast(target.method(for: sel), to: Fn.self)(target, sel, value)
    }

    private static func setInt(_ target: NSObject, selector: String, value: Int) {
        let sel = NSSelectorFromString(selector)
        guard target.responds(to: sel) else { return }
        typealias Fn = @convention(c) (NSObject, Selector, Int) -> Void
        unsafeBitCast(target.method(for: sel), to: Fn.self)(target, sel, value)
    }

    private static func setUInt(_ target: NSObject, selector: String, value: UInt) {
        let sel = NSSelectorFromString(selector)
        guard target.responds(to: sel) else { return }
        typealias Fn = @convention(c) (NSObject, Selector, UInt) -> Void
        unsafeBitCast(target.method(for: sel), to: Fn.self)(target, sel, value)
    }

    private static func setRect(_ target: NSObject, selector: String, value: CGRect) {
        let sel = NSSelectorFromString(selector)
        guard target.responds(to: sel) else { return }
        typealias Fn = @convention(c) (NSObject, Selector, CGRect) -> Void
        unsafeBitCast(target.method(for: sel), to: Fn.self)(target, sel, value)
    }
}

/// UIKit backdrop placed behind all subviews of `RootSplitController` on Mac.
/// Stays whisper-translucent over the AppKit `NSVisualEffectView`, switching to a solid calm surface
/// under Reduce Transparency.
final class MacShellBackdrop: UIView {
    private var themeToken: NSObjectProtocol?
    private var a11yToken: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        isOpaque = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self, UITraitAccessibilityContrast.self]) {
            (view: MacShellBackdrop, _) in view.refresh()
        }
        themeToken = NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        a11yToken = NotificationCenter.default.addObserver(forName: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        if let themeToken { NotificationCenter.default.removeObserver(themeToken) }
        if let a11yToken { NotificationCenter.default.removeObserver(a11yToken) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refresh()
    }

    func refresh() {
        let reduced = HQAccessibility.reduceTransparency
        backgroundColor = reduced ? MacGlassShell.fallbackShellColor : MacGlassShell.glassVeilColor
        MacGlassShell.apply(to: window)
    }
}
#endif
