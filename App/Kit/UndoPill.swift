// The Undo pill (spec 1x-settings §5.3, `S/ui-kit/undo-pill.tsx`): an interactive glass capsule floating 8 pt above the
// tab bar — "Hidden · Undo" — for 4 s (8 s at accessibility text sizes; "Deleted “Work”" 8 s always), held while touched
// or VoiceOver-focused. It shows with the change itself (not after the gateway answered); a write that fails takes it
// away as its alert shows. Not the tab bar's bottom accessory (the owner rejected that slot).

import UIKit

/// The pill's clock, kept apart from the view so its rules are unit-tested (`S/ui-kit/undo-pill.tsx`, parity §3 L237):
/// it runs only while nothing holds it — a finger on the pill, VoiceOver focus inside it, or the Talk "away" pill
/// covering its place — and a hold keeps what was left, so the pill resumes instead of starting over.
nonisolated struct UndoPillClock: Equatable, Sendable {
    enum Hold: Hashable, Sendable { case finger, voiceOver, away, pointer }

    /// Seconds still to show once nothing holds it.
    private(set) var remaining: TimeInterval
    private(set) var holds: Set<Hold> = []
    private var runningSince: Date?

    /// 4 s as asked, at least 8 s at accessibility text sizes (chosen when the pill is made).
    init(duration: TimeInterval, accessibilitySize: Bool) {
        remaining = accessibilitySize ? max(8, duration) : duration
    }

    var isRunning: Bool { runningSince != nil }

    /// Starts (or resumes) the clock when nothing holds it: the seconds until the pill goes, or nil while held.
    mutating func resume(now: Date) -> TimeInterval? {
        guard holds.isEmpty else { return nil }
        if runningSince == nil { runningSince = now }
        return left(now: now)
    }

    /// A hold begins: the clock stops and keeps what is left.
    mutating func hold(_ hold: Hold, now: Date) {
        if let since = runningSince {
            remaining = max(0, remaining - now.timeIntervalSince(since))
            runningSince = nil
        }
        holds.insert(hold)
    }

    /// A hold ends: the seconds until the pill goes if the clock runs again, nil while another hold stands.
    mutating func release(_ hold: Hold, now: Date) -> TimeInterval? {
        holds.remove(hold)
        return resume(now: now)
    }

    func left(now: Date) -> TimeInterval {
        guard let since = runningSince else { return remaining }
        return max(0, remaining - now.timeIntervalSince(since))
    }
}

final class UndoPill: UIView {
    /// Whether the Talk "away" pill is up over the tab bar (it takes the place; the Undo pill waits). Tests replace it.
    static var awayPillShowing: () -> Bool = { TalkAwayPill.isShowing }
    /// The clock's "now" (tests replace it).
    static var now: () -> Date = { Date() }
    /// The pill on show or waiting for the away pill to go (tests read it).
    static var current: UndoPill? { shown }

    private static weak var shown: UndoPill?

    private let glass: UIVisualEffectView = {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        let view = UIVisualEffectView(effect: effect)
        view.cornerConfiguration = .capsule()
        return view
    }()
    private let label = UILabel()
    private let button = UIButton(type: .system)
    private let dot = UILabel()
    /// The smaller lines under the words (the way back, the detail).
    private var lines: [UILabel] = []
    private let wayBack: String?
    private var onUndo: (() -> Void)?
    private var timer: Timer?
    private(set) var clock = UndoPillClock(duration: 4, accessibilitySize: false)
    /// The page the change was made on: a pill that waited out the away pill is dropped if that page has gone.
    private weak var origin: UIViewController?
    private var awayObserver: NSObjectProtocol?
    private var announced = false
    /// What VoiceOver hears when the pill shows: the words, the way back and the detail line.
    private var announcement = ""
    /// On screen (not waiting behind the away pill).
    var isOnShow: Bool { !isHidden && superview != nil }

    /// Shows a pill over `host` (a tab controller's view, or any view with a tab bar above its bottom) for `duration`
    /// seconds (at least 8 at accessibility text sizes). UX study #152: every "did X · Undo" notice is this pill —
    /// `detail` is a line under the words (Kanban's "Archived tasks are on the desktop board."), `actionTitle` the
    /// button's word when it is not Undo (Artifacts' "Downloading … · Cancel"). `showsWayBack`: the way back is also
    /// drawn, a smaller line under the words (else only VoiceOver reads it).
    @discardableResult
    static func show(label: String, wayBack: String? = nil, showsWayBack: Bool = false, detail: String? = nil,
                     actionTitle: String = "Undo", duration: TimeInterval = 4, in host: UIViewController?,
                     showsUndo: Bool = true,   // [groups] false: a plain notice ("“Launch Room” was deleted.")
                     onUndo: @escaping () -> Void) -> UndoPill? {
        let origin = host
        guard let given = host?.tabBarController ?? host, let givenView = given.view else { return nil }
        #if targetEnvironment(macCatalyst)
        let (host, view, messageBar) = shownPane(given, givenView)
        #else
        let (host, view) = (given, givenView)
        #endif
        shown?.dismiss(animated: false)
        var duration = duration
        #if DEBUG
        // [sessions-m9] UI tests (`-HQDebugUndoSeconds 30`): a busy simulator can take longer than the pill lasts to
        // answer the queries a test makes before it presses Undo.
        duration = max(duration, UserDefaults.standard.double(forKey: "HQDebugUndoSeconds"))
        #endif
        let pill = UndoPill(label: label, wayBack: wayBack, showsWayBack: showsWayBack, detail: detail, actionTitle: actionTitle,
                            duration: duration, showsUndo: showsUndo, onUndo: onUndo)
        pill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pill)
        // [desktoplook] The bar the pill sits over must share the host's view tree (as `PagesHUD`): with Desktop Look
        // on, the system tab bar is hidden and not under `view`, and the docked bar stands in for it.
        let docked = view.subviews.last { $0 is DesktopTabBar && !$0.isHidden }
        let tabBar = docked ?? (host as? UITabBarController).flatMap { tabs -> UIView? in
            let bar = tabs.tabBar
            return !tabs.isTabBarHidden && !bar.isHidden && bar.isDescendant(of: view) ? bar : nil
        }
        let bottom = tabBar.map { pill.bottomAnchor.constraint(equalTo: $0.topAnchor, constant: -8) }
            ?? pill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        #if targetEnvironment(macCatalyst)
        if let messageBar, messageBar.isDescendant(of: view) {
            // Over the message bar while the chat is there; at the pane's foot should the chat go first.
            bottom.priority = .defaultLow
            pill.bottomAnchor.constraint(lessThanOrEqualTo: messageBar.topAnchor, constant: -8).isActive = true
        }
        #endif
        NSLayoutConstraint.activate([
            bottom,
            pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            pill.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
        ])
        pill.wrapLines(within: view.bounds.width - 32)
        shown = pill
        pill.origin = origin
        pill.begin()
        #if targetEnvironment(macCatalyst)
        // [mac] Stress test 2026-10-28 #34: Edit › Undo (⌘Z) is the pill's Undo while it shows ("Undo Archived").
        if showsUndo, actionTitle == "Undo", let manager = view.window?.undoManager {
            manager.registerUndo(withTarget: pill) { pill in MainActor.assumeIsolated { pill.undo() } }
            manager.setActionName(label)
            pill.registeredUndo = manager
        }
        #endif
        return pill
    }

    #if targetEnvironment(macCatalyst)
    /// [mac] Mac polish #32: a list folded out of sight (the Bots list: the Mac's bots are in its sidebar) puts the pill
    /// over the pane on show beside it instead, above a chat's message bar there: in the hidden list it never showed.
    private static func shownPane(_ host: UIViewController, _ view: UIView) -> (UIViewController, UIView, messageBar: UIView?) {
        guard view.isHidden, let split = (host as? MainTabController)?.split, let pane = split.detail.viewIfLoaded,
              !pane.isHidden else { return (host, view, nil) }
        return (split.detail, pane, (split.detail.topViewController as? ChatViewController)?.composer)
    }
    #endif

    private init(label text: String, wayBack: String?, showsWayBack: Bool = false, detail: String?, actionTitle: String,
                 duration: TimeInterval, showsUndo: Bool = true, onUndo: @escaping () -> Void) {
        self.wayBack = wayBack
        self.onUndo = onUndo
        super.init(frame: .zero)
        accessibilityIdentifier = "undo-pill"
        addSubview(glass)
        glass.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.font = HQFont.preferred(.subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = HQPalette.label
        label.numberOfLines = 2
        label.isAccessibilityElement = true
        label.accessibilityLabel = [text, wayBack].compactMap { $0 }.joined(separator: ". ")
        announcement = [text, wayBack, detail].compactMap { $0 }.joined(separator: ". ")
        var config = UIButton.Configuration.plain()
        config.title = actionTitle
        config.baseForegroundColor = HQPalette.tint
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var next = attributes
            next.font = HQFont.preferred(.subheadline).withWeight(.semibold)
            return next
        }
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 14)
        button.configuration = config
        button.accessibilityIdentifier = "undo-pill.undo"
        // A long name wraps the words; "Undo" keeps its width.
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        // Over the row's rule for wrapping text (priority 950, which folded "Deleted “Plain words”" onto two short
        // lines in a 620 pt sheet on the Mac); it wraps at the width `wrapLines` gives it, and still yields to Undo.
        label.setContentCompressionResistancePriority(.required - 1, for: .horizontal)
        button.addAction(UIAction { [weak self] _ in self?.undo() }, for: .primaryActionTriggered)
        dot.text = "·"
        dot.textColor = HQPalette.label3
        dot.font = HQFont.preferred(.subheadline)
        dot.isAccessibilityElement = false
        dot.setContentCompressionResistancePriority(.required, for: .horizontal)
        dot.setContentHuggingPriority(.required, for: .horizontal)
        // Smaller lines under the words: [sessions] the way back drawn (the words' own element already reads it to
        // VoiceOver), and the detail line.
        let lines: [(text: String, spoken: Bool)] = [showsWayBack ? wayBack.map { ($0, false) } : nil,
                                                     detail.map { ($0, true) }].compactMap { $0 }
        var words: UIView = label
        if !lines.isEmpty {
            // Two lines make the capsule a rounded card (as the HUD's was).
            let under = lines.map { line -> UILabel in
                let lineLabel = UILabel()
                lineLabel.text = line.text
                lineLabel.font = HQFont.preferred(.footnote)
                lineLabel.adjustsFontForContentSizeCategory = true
                lineLabel.textColor = HQPalette.label2
                lineLabel.numberOfLines = 0
                // Over the row's own rule for wrapping text (the words at most half its width, priority 950); it
                // wraps at the width `wrapLines` gives it instead.
                lineLabel.setContentCompressionResistancePriority(.required - 1, for: .horizontal)
                lineLabel.isAccessibilityElement = line.spoken
                return lineLabel
            }
            self.lines = under
            let stack = UIStackView(arrangedSubviews: [label] + under)
            stack.axis = .vertical
            stack.spacing = 1
            stack.alignment = .leading
            stack.isLayoutMarginsRelativeArrangement = showsUndo   // without Undo the row has these margins
            stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0)
            words = stack
            glass.cornerConfiguration = .uniformCorners(radius: .fixed(22))
        }
        let row = UIStackView(arrangedSubviews: [words, dot, button])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 6
        if !showsUndo {   // [groups] nothing to undo: the words alone, with the pill's own side padding
            dot.isHidden = true
            button.isHidden = true
            row.isLayoutMarginsRelativeArrangement = true
            row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 18)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        // A resting finger holds it.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(holding(_:)))
        hold.minimumPressDuration = 0
        hold.cancelsTouchesInView = false
        hold.delegate = self
        addGestureRecognizer(hold)
        // [mac] Stress test 2026-10-28 #34: the pointer resting on it holds it, as a finger does.
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovering(_:)))
        addGestureRecognizer(hover)
        clock = UndoPillClock(duration: duration,
                              accessibilitySize: UITraitCollection.current.preferredContentSizeCategory.isAccessibilityCategory
                                || UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory)
        // The Undo button says what it undoes (`undo-pill.tsx`: "<label>. <way back> Undo").
        button.accessibilityLabel = ([text, wayBack, detail].compactMap { $0 } + [actionTitle]).joined(separator: ". ")
        // [botslist] The away pill showing or going (`TalkAwayPill.changed`): this pill gives it the place and comes back after.
        awayObserver = NotificationCenter.default.addObserver(forName: TalkAwayPill.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.awayChanged() }
        }
        // A block observer on the main queue (a main-actor selector observer traps if a post ever comes off main).
        focusObserver = NotificationCenter.default.addObserver(forName: UIAccessibility.elementFocusedNotification, object: nil,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.focusChanged(UIAccessibility.focusedElement(using: .notificationVoiceOver) as AnyObject?)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var focusObserver: NSObjectProtocol?
    /// [mac] Where ⌘Z finds this pill's Undo (the window's), cleared as the pill goes.
    private weak var registeredUndo: UndoManager?

    isolated deinit {
        timer?.invalidate()
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        if let awayObserver { NotificationCenter.default.removeObserver(awayObserver) }
    }

    /// The lines under the words wrap at the width the pill can have. Left to the row, "Archived tasks are on the
    /// desktop board." folded into four short lines whatever the room (seen on the Mac, 2026-10-23).
    private func wrapLines(within width: CGFloat) {
        let beside = button.isHidden ? 18 : dot.intrinsicContentSize.width + button.intrinsicContentSize.width + 12
        for line in lines { line.preferredMaxLayoutWidth = max(120, width - 18 - beside) }
        label.preferredMaxLayoutWidth = max(120, width - 18 - beside)
    }

    /// Shows now, or waits (not drawn, clock not started) while the away pill has the place.
    private func begin() {
        if Self.awayPillShowing() {
            isHidden = true
            clock.hold(.away, now: Self.now())
        } else {
            appear()
        }
    }

    /// The away pill showed or went. Never both at once: this pill fades and keeps its remaining time, and comes back
    /// when the away pill goes — unless the page the change was made on has left the screen (the change stands).
    func awayChanged() {
        let away = Self.awayPillShowing()
        if away, !clock.holds.contains(.away) {
            clock.hold(.away, now: Self.now())
            timer?.invalidate(); timer = nil
            guard !HQMotion.reduced else { isHidden = true; return }
            UIView.animate(withDuration: 0.2, animations: { self.alpha = 0 }, completion: { _ in   // motion-ok: a fade
                if self.clock.holds.contains(.away) { self.isHidden = true }
            })
        } else if !away, clock.holds.contains(.away) {
            if let origin, origin.viewIfLoaded?.window == nil { dismiss(animated: false); return }
            isHidden = false
            _ = clock.release(.away, now: Self.now())
            appear()
        }
    }

    private func appear() {
        alpha = 0
        transform = CGAffineTransform(translationX: 0, y: 12)
        UIView.animate(withDuration: HQMotion.reduced ? 0.01 : 0.28, delay: 0, options: [.curveEaseOut]) {
            self.alpha = 1
            self.transform = .identity
        }
        if !announced { announced = true; HQAnnounce.say(announcement) }   // once, not again after a wait
        resumeClock()
    }

    /// Runs the clock for what is left of it (a hold keeps the remainder: it resumes, it does not start over).
    private func resumeClock() {
        timer?.invalidate(); timer = nil
        guard let left = clock.resume(now: Self.now()) else { return }
        arm(left)
    }

    private func arm(_ seconds: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: max(0.01, seconds), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(animated: true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setHold(_ hold: UndoPillClock.Hold, _ on: Bool) {
        if on {
            guard !clock.holds.contains(hold) else { return }
            clock.hold(hold, now: Self.now())
            timer?.invalidate(); timer = nil
        } else {
            guard clock.holds.contains(hold) else { return }
            if let left = clock.release(hold, now: Self.now()) { arm(left) }
        }
    }

    @objc private func holding(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began: setHold(.finger, true)          // on touch-down (the recogniser's press time is zero)
        case .ended, .cancelled, .failed: setHold(.finger, false)
        default: break
        }
    }

    @objc private func hovering(_ gesture: UIHoverGestureRecognizer) {
        switch gesture.state {
        case .began, .changed: setHold(.pointer, true)
        default: setHold(.pointer, false)
        }
    }

    private func focusChanged(_ focused: AnyObject?) {
        let inside = (focused as? UIView).map { $0.isDescendant(of: self) } ?? false
        setHold(.voiceOver, inside)
    }

    private func undo() {
        let action = onUndo
        onUndo = nil
        // A light tap that the change was taken back (the pill going is the rest of the answer). Only when there was
        // something to undo: a second press while the pill fades plays nothing.
        if action != nil { Haptics.play(.light) }
        dismiss(animated: true)
        action?()
    }

    func dismiss(animated: Bool) {
        timer?.invalidate()
        timer = nil
        registeredUndo?.removeAllActions(withTarget: self)
        guard animated, !HQMotion.reduced, !isHidden else { removeFromSuperview(); return }
        UIView.animate(withDuration: 0.2, animations: { self.alpha = 0 }, completion: { _ in self.removeFromSuperview() })
    }
}

extension UndoPill: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
