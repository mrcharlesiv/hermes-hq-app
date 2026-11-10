// [a11y] The one place that knows the accessibility settings (spec 3x-a11y §2.1). Every call site reads
// `HQAccessibility.current` (or `HQMotion.reduced`), never `UIAccessibility.is…` directly: the DEBUG launch
// overrides below only work that way, and a lint test (Tests/Accessibility/A11yLintTests.swift) keeps it so.

import UIKit
import os

enum HQAccessibility {
    struct Settings: Equatable, Sendable {
        var reduceMotion = false
        var reduceTransparency = false
        var increaseContrast = false
        var boldText = false
        var buttonShapes = false
        var voiceOver = false
        var switchControl = false
        var contentSize: UIContentSizeCategory = .large
        var isAccessibilitySize: Bool { contentSize.isAccessibilityCategory }
        /// AX2 and larger: the chat title drops its face, rows stack (spec 06 §10).
        var isLargeAccessibilitySize: Bool { contentSize.isAccessibilityCategory && contentSize != .accessibilityMedium }
    }

    static let didChange = Notification.Name("HQAccessibility.didChange")

    /// The simulator's command line can set only the text size and Increase Contrast, so DEBUG builds take
    /// `-HQA11yReduceMotion YES`, `-HQA11yReduceTransparency YES`, `-HQA11yBoldText YES`, `-HQA11yButtonShapes YES`,
    /// `-HQA11yVoiceOver YES` and `-HQA11yContrast YES`. A set override forces the setting on; it never turns a real
    /// setting off. `-HQA11yVoiceOver` changes only the app's own VoiceOver-dependent behaviour; it cannot make the
    /// system speak.
    struct Overrides: Equatable, Sendable {
        var reduceMotion = false, reduceTransparency = false, boldText = false, buttonShapes = false
        var voiceOver = false, contrast = false

        nonisolated static func parse(_ defaults: UserDefaults) -> Overrides {
            #if DEBUG
            return Overrides(reduceMotion: defaults.bool(forKey: "HQA11yReduceMotion"),
                             reduceTransparency: defaults.bool(forKey: "HQA11yReduceTransparency"),
                             boldText: defaults.bool(forKey: "HQA11yBoldText"),
                             buttonShapes: defaults.bool(forKey: "HQA11yButtonShapes"),
                             voiceOver: defaults.bool(forKey: "HQA11yVoiceOver"),
                             contrast: defaults.bool(forKey: "HQA11yContrast"))
            #else
            return Overrides()
            #endif
        }
    }

    nonisolated static let overrides = Overrides.parse(.standard)

    // Cheap, thread-safe reads for the hot paths (display links, colour providers, off-main layout). UIKit's own
    // reads are main-actor only in this SDK, so the last values read on the main actor are kept here.
    private struct Flags: Sendable { var reduceMotion = false, reduceTransparency = false, boldText = false, buttonShapes = false, voiceOver = false, systemBoldsFonts = false }
    nonisolated private static let flags = OSAllocatedUnfairLock(initialState: Flags())
    nonisolated private static let primed = OSAllocatedUnfairLock(initialState: false)

    /// Reads the system's settings into the thread-safe copy. Main actor.
    static func sync() {
        let now = Flags(reduceMotion: UIAccessibility.isReduceMotionEnabled, reduceTransparency: UIAccessibility.isReduceTransparencyEnabled,
                        boldText: UIAccessibility.isBoldTextEnabled, buttonShapes: UIAccessibility.buttonShapesEnabled,
                        voiceOver: UIAccessibility.isVoiceOverRunning,
                        systemBoldsFonts: fontIsAlreadyBold(HQFont.system(ofSize: 17)))
        flags.withLock { $0 = now }
        primed.withLock { $0 = true }
    }

    nonisolated private static var live: Flags {
        if !primed.withLock({ $0 }), Thread.isMainThread { MainActor.assumeIsolated { sync() } }
        return flags.withLock { $0 }
    }

    nonisolated static var reduceMotion: Bool { overrides.reduceMotion || live.reduceMotion }
    nonisolated static var reduceTransparency: Bool { overrides.reduceTransparency || live.reduceTransparency }
    nonisolated static var boldText: Bool { overrides.boldText || live.boldText }
    nonisolated static var buttonShapes: Bool { overrides.buttonShapes || live.buttonShapes }
    /// With the real Bold Text setting UIKit already hands out heavier faces, also to text the app draws itself
    /// (`systemFont(ofSize:)` comes back at about medium weight instead of regular). Then the app must not step the
    /// weights up a second time.
    nonisolated static var systemBoldsFonts: Bool { live.systemBoldsFonts }
    /// Whether the app must make its own drawn text heavier: Bold Text is on and the system has not done it.
    nonisolated static var stepsDrawnWeights: Bool { stepsDrawnWeights(boldText: boldText, systemBoldsFonts: systemBoldsFonts) }
    nonisolated static func stepsDrawnWeights(boldText: Bool, systemBoldsFonts: Bool) -> Bool { boldText && !systemBoldsFonts }
    /// A regular system font reports weight 0; anything clearly above it means the system has bolded it.
    nonisolated static func fontIsAlreadyBold(_ font: UIFont) -> Bool {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        return ((traits?[.weight] as? CGFloat) ?? 0) > 0.1
    }
    nonisolated static var voiceOver: Bool { overrides.voiceOver || live.voiceOver }
    static var increaseContrast: Bool { overrides.contrast || UIAccessibility.isDarkerSystemColorsEnabled }
    /// VoiceOver or Switch Control: someone who cannot swipe needs every gesture as an action.
    static var assistiveTouching: Bool { voiceOver || UIAccessibility.isSwitchControlRunning }

    /// The size from the last size notification wins over `UIApplication`'s, which can still read the old value when
    /// the notification arrives (web note r4-47, HermesViewController.swift:945-948).
    private static var notifiedSize: UIContentSizeCategory?

    static var current: Settings {
        sync()
        return settings(size: notifiedSize ?? UIApplication.shared.preferredContentSizeCategory)
    }

    static func settings(size: UIContentSizeCategory, overrides o: Overrides = overrides) -> Settings {
        Settings(reduceMotion: o.reduceMotion || UIAccessibility.isReduceMotionEnabled,
                 reduceTransparency: o.reduceTransparency || UIAccessibility.isReduceTransparencyEnabled,
                 increaseContrast: o.contrast || UIAccessibility.isDarkerSystemColorsEnabled,
                 boldText: o.boldText || UIAccessibility.isBoldTextEnabled,
                 buttonShapes: o.buttonShapes || UIAccessibility.buttonShapesEnabled,
                 voiceOver: o.voiceOver || UIAccessibility.isVoiceOverRunning,
                 switchControl: UIAccessibility.isSwitchControlRunning,
                 contentSize: size)
    }

    private static var last: Settings?
    private static var tokens: [NSObjectProtocol] = []
    /// Times `didChange` was posted (tests).
    private(set) static var changeCount = 0

    /// Called once from the app delegate.
    static func start() {
        guard tokens.isEmpty else { return }
        sync()
        last = current
        let names: [Notification.Name] = [
            UIAccessibility.reduceMotionStatusDidChangeNotification,
            UIAccessibility.reduceTransparencyStatusDidChangeNotification,
            UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
            UIAccessibility.boldTextStatusDidChangeNotification,
            UIAccessibility.buttonShapesEnabledStatusDidChangeNotification,
            UIAccessibility.voiceOverStatusDidChangeNotification,
            UIAccessibility.switchControlStatusDidChangeNotification,
            UIContentSizeCategory.didChangeNotification,
            UIApplication.didBecomeActiveNotification,
        ]
        for name in names {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                let size = (note.userInfo?[UIContentSizeCategory.newValueUserInfoKey] as? String).map(UIContentSizeCategory.init(rawValue:))
                let active = note.name == UIApplication.didBecomeActiveNotification
                MainActor.assumeIsolated { refresh(notifiedSize: size, forgetNotified: active) }
            })
        }
        #if DEBUG
        HQTestQuit.installIfAsked()
        tokens.append(NotificationCenter.default.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HQA11yAudit.install() }
        })
        #endif
    }

    /// Re-reads the settings and posts `didChange` only when something really changed.
    static func refresh(notifiedSize size: UIContentSizeCategory? = nil, forgetNotified: Bool = false) {
        if forgetNotified { notifiedSize = nil }
        if let size { notifiedSize = size }
        consider(current)
    }

    /// Split out for the unit tests: posts once per real change.
    @discardableResult static func consider(_ now: Settings) -> Bool {
        guard now != last else { return false }
        last = now
        changeCount += 1
        NotificationCenter.default.post(name: didChange, object: nil)
        return true
    }
}

extension UISheetPresentationController {
    /// R4 (spec 3x-a11y §4.2): a sheet that offers a shorter detent opens large at accessibility text sizes (the
    /// web's memo and Talk sheets do, HermesVoice.swift:120-126,669-672). The other detents stay available.
    func hqPreferLargeAtAccessibilitySizes() {
        guard HQAccessibility.current.isAccessibilitySize else { return }
        if !detents.contains(where: { $0.identifier == .large }) { detents.append(.large()) }
        selectedDetentIdentifier = .large
    }
}
