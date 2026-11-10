// [presence] "<bot> is using its browser" / "<bot> is using its screen", with Watch (docs/spec/3x-presence.md §8.3;
// the web app's startPhoneScreenNudges, R:src/bot-screen-menu.tsx:83-114). A Liquid Glass capsule — the system's own
// untinted glass — at Apple's banner spot, built like the reply peek (App/Notifications/ReplyPeek.swift): the bot's
// face, the words, and "Watch" in the tint colour. The whole capsule is one button; a swipe up sends it away; it leaves
// by itself after 8 s (16 s with VoiceOver, and never while touched or VoiceOver-focused). One notice at a time: the same
// bot's next notice refreshes it, another bot's replaces it, and it never shares the banner spot with a reply peek.
//
// Touches (spec §8.3, DECISION D36): ONE recognizer follows ONE finger from down to up, and what the touch was is
// decided once, when it ends, from where it went: a finger that moved more than 10 pt is never a tap; up by more
// than 18 pt (or a flick up) sends the notice away; anything else springs back. "Held" is a fact per holder (the
// finger, VoiceOver's cursor), not a count, so a late or missing callback cannot leave the leave timer off.

import UIKit
import UIKit.UIGestureRecognizerSubclass

@MainActor final class PresenceNotice: NSObject {
    static let shared = PresenceNotice()

    /// `browserAsk`: the bot's browser is waiting for the person (a sign-in step, a code, a CAPTCHA; UX study #135).
    nonisolated enum Kind: Sendable, Equatable { case browser, screen, browserAsk }

    struct Alert {
        var profile: String
        var name: String
        var kind: Kind
        /// The face and whether it is the bot's photo (an app-icon tile, never cut to a circle), as the reply peek.
        var face: BotFaces.Face?

        var message: String { PresenceNotice.message(name: name, kind: kind) }
        var drawn: String { PresenceNotice.drawn(name: name, kind: kind) }
        var hint: String { kind == .screen ? "Opens its screen" : "Opens its browser" }
    }

    /// The exact words (R:src/bot-screen-menu.tsx:108,112); an ask says what the chat's card says (`BrowserCard.words`).
    nonisolated static func message(name: String, kind: Kind) -> String {
        switch kind {
        case .browser: "\(name) is using its browser"
        case .screen: "\(name) is using its screen"
        case .browserAsk: "\(name) needs you in its browser"
        }
    }

    /// The words as drawn: the name is set apart (first-strong isolate … pop isolate), so a right-to-left name reads
    /// in its own direction and the sentence keeps its order ("<name> is using its browser", not "is using <name>").
    nonisolated static func drawn(name: String, kind: Kind) -> String {
        "\u{2068}\(name)\u{2069}" + message(name: "", kind: kind)
    }

    static let minHeight: CGFloat = 64

    private(set) var view: NoticeView?
    private var timer: Timer?
    private var current: Alert?
    private var onWatch: ((Alert) -> Void)?
    /// Who keeps it on screen. A set, not a count: holding twice is holding once, and letting go is final.
    nonisolated enum Holder: Sendable, Hashable { case touch, voiceOver }
    private var holders: Set<Holder> = []
    /// A finger that has not moved for this long no longer holds the notice (DECISION D37): nothing may keep a
    /// notice on screen for good, not even a touch whose lift never arrives.
    var restingFingerSeconds: TimeInterval = 30
    private var restingTimer: Timer?
    private var background: NSObjectProtocol?

    var isShowing: Bool { view != nil }
    /// The bot the notice on screen is about.
    var showingProfile: String? { view == nil ? nil : current?.profile }

    func show(_ alert: Alert, in window: UIWindow, onWatch: @escaping (Alert) -> Void) {
        // One banner at the banner spot: the newer one wins.
        ReplyPeek.shared.dismiss(up: true)
        self.onWatch = onWatch
        let replacing = view != nil && view?.window === window && view?.leaving == false
        let sameBot = replacing && current?.profile == alert.profile
        if !replacing { view?.removeFromSuperview(); view = nil }
        current = alert
        let notice = replacing ? view! : makeView(in: window)
        if replacing && !sameBot {
            UIView.transition(with: notice.contentStack, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]) { notice.fill(alert) }   // motion-ok: cross-dissolve, nothing moves
        } else {
            notice.fill(alert)
        }
        layout(notice, in: window)
        if !replacing { appear(notice) }
        HQAnnounce.say(alert.message)
        // A capsule that is refreshed or handed to another bot under a finger or VoiceOver's cursor is still held: it
        // stays until that hold is let go, and only then starts its 8 s. A new capsule starts with no holds.
        if !replacing { holders = []; restingTimer?.invalidate(); restingTimer = nil }
        if holders.isEmpty { restartTimer() }
        if background == nil {
            // Left for another app: the notice is old news by the return.
            background = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss(up: true, animated: false) }
            }
        }
    }

    /// The viewer for this bot opened some other way: its notice has nothing left to offer.
    func dismiss(about profile: String) {
        if showingProfile == profile { dismiss(up: true) }
    }

    /// That bot's chat opened: its card says what the ask notice says, so the notice goes (not left over the chat's ⋯).
    func dismissAsk(about profile: String) {
        if showingProfile == profile, current?.kind == .browserAsk { dismiss(up: true) }
    }

    private func makeView(in window: UIWindow) -> NoticeView {
        let notice = NoticeView()
        // Only the capsule on screen speaks: one that is on its way out (its gestures can still end) changes nothing.
        notice.onTap = { [weak self, weak notice] in
            guard let self, let notice, notice === self.view, let alert = self.current else { return }
            Haptics.play(.light)
            let watch = self.onWatch
            self.dismiss(up: false)
            watch?(alert)
        }
        notice.onDismiss = { [weak self, weak notice] in
            guard let self, let notice, notice === self.view else { return }
            self.dismiss(up: true)
        }
        notice.onHold = { [weak self, weak notice] holder, holding in
            guard let self, let notice, notice === self.view else { return }
            self.hold(holding, by: holder)
        }
        notice.onSizeChange = { [weak self, weak notice] in
            guard let self, let notice, let window = notice.window, notice === self.view else { return }
            notice.applyTextSize()
            self.layout(notice, in: window)
        }
        window.addSubview(notice)
        view = notice
        return notice
    }

    /// A finger on it, or VoiceOver's cursor: it stays. The two can overlap; each lets go for itself only.
    func hold(_ holding: Bool, by holder: Holder = .touch) {
        guard view != nil else { return }
        let was = holders
        if holding { holders.insert(holder) } else { holders.remove(holder) }
        if !holders.isEmpty { timer?.invalidate(); timer = nil }
        else if !was.isEmpty || timer == nil { restartTimer() }
        if holder == .touch {
            restingTimer?.invalidate(); restingTimer = nil
            if holding { watchRestingFinger(after: restingFingerSeconds) }
        }
    }

    /// While a finger holds the notice: has it moved lately? One that has been still for `restingFingerSeconds` is
    /// let go of, and the notice leaves.
    private func watchRestingFinger(after seconds: TimeInterval) {
        restingTimer = Timer.scheduledTimer(withTimeInterval: max(0.05, seconds), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let notice = self.view, self.holders.contains(.touch) else { return }
                let still = notice.secondsSinceTouchMoved
                if still + 0.01 >= self.restingFingerSeconds {
                    AppLog.note("presence", "notice: a finger rested on it for \(Int(still)) s; leaving")
                    self.dismiss(up: true)
                } else {
                    self.watchRestingFinger(after: self.restingFingerSeconds - still)
                }
            }
        }
    }

    /// What a touch on the capsule was, decided once when it ends. `travel` is the farthest the finger got from where
    /// it landed, `rise` how far it ended above (negative) or below that point, `speed` its vertical speed at the lift
    /// (points per second, negative upwards).
    nonisolated enum TouchOutcome: Sendable, Equatable { case tap, dismiss, settle }
    nonisolated static let tapSlop: CGFloat = 10
    nonisolated static func outcome(travel: CGFloat, rise: CGFloat, speed: CGFloat) -> TouchOutcome {
        if rise < -18 { return .dismiss }
        if travel <= tapSlop { return .tap }
        if rise < 0 && speed < -300 { return .dismiss }
        return .settle
    }

    private static let measure = UILabel()

    /// The words as drawn, with a name too long for the room shortened ("Averyveryl… is using its browser") so the
    /// fixed words are never the part that is cut off.
    static func fitted(name: String, kind: Kind, font: UIFont, width: CGFloat, lines: Int = 2) -> String {
        let whole = drawn(name: name, kind: kind)
        guard width > 0 else { return whole }
        let label = measure
        label.numberOfLines = 0
        label.font = font
        let limit = ceil(font.lineHeight * CGFloat(lines)) + 1
        func fits(_ text: String) -> Bool {
            label.text = text
            return label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height <= limit
        }
        if fits(whole) { return whole }
        let letters = Array(name)
        func cut(_ count: Int) -> String {
            drawn(name: String(letters.prefix(count)).trimmingCharacters(in: .whitespaces) + "…", kind: kind)
        }
        var low = 1, high = max(1, letters.count - 1)
        while low < high {
            let middle = (low + high + 1) / 2
            if fits(cut(middle)) { low = middle } else { high = middle - 1 }
        }
        return cut(low)
    }

    /// The leave timer is running (false while the capsule is held).
    var timerArmed: Bool { timer != nil }

    private func layout(_ notice: NoticeView, in window: UIWindow) {
        let inset: CGFloat = 12
        let width = max(120, min(window.bounds.width - inset * 2 - window.safeAreaInsets.left - window.safeAreaInsets.right, 440))
        // Apple's banner spot: just under the status bar and the Dynamic Island.
        let y = window.safeAreaInsets.top + 2
        notice.applyTextSize()
        notice.fitWords(forWidth: width)
        let height = max(Self.minHeight, ceil(notice.contentHeight(forWidth: width)) + 24)
        let resting = CGPoint(x: window.bounds.midX, y: y + height / 2)
        let moved = notice.transform
        notice.transform = .identity
        notice.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        notice.center = resting
        notice.resting = resting
        notice.transform = moved
        notice.layoutIfNeeded()
    }

    private func appear(_ notice: NoticeView) {
        notice.materialize(false)
        if HQMotion.reduced {
            notice.alpha = 0
            notice.materialize(true)
            UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction]) { notice.alpha = 1 }
            return
        }
        notice.alpha = 0
        notice.transform = CGAffineTransform(translationX: 0, y: -24).scaledBy(x: 0.9, y: 0.9)
        // Touchable while it arrives: an animated view takes no touches by default, and a tap in the capsule's first
        // half second was dropped (seen once in a UI run: the tap landed and nothing opened).
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0.4,   // motion-ok: Reduce Motion took the fade-only path at the top of appear(_:)
                       options: [.allowUserInteraction]) {
            notice.alpha = 1
            notice.transform = .identity
            notice.materialize(true)
        }
    }

    /// How long a notice left alone stays (seconds).
    static func shownFor(voiceOver: Bool, hold: Bool) -> TimeInterval {
        if hold { return 60 }
        return voiceOver ? ScreenTools.noticeSeconds * 2 : ScreenTools.noticeSeconds
    }

    private func restartTimer() {
        timer?.invalidate()
        var hold = false
        #if DEBUG
        // UI tests read the capsule before it leaves.
        hold = UserDefaults.standard.bool(forKey: "HQDebugNoticeHold")
        #endif
        let shown = Self.shownFor(voiceOver: HQAccessibility.voiceOver, hold: hold)
        timer = Timer.scheduledTimer(withTimeInterval: shown, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(up: true) }
        }
    }

    func dismiss(up: Bool) { dismiss(up: up, animated: true) }

    private func dismiss(up: Bool, animated: Bool) {
        timer?.invalidate(); timer = nil
        restingTimer?.invalidate(); restingTimer = nil
        holders = []
        guard let notice = view, !notice.leaving else { return }
        notice.leaving = true
        view = nil
        current = nil
        onWatch = nil
        guard animated else { notice.removeFromSuperview(); return }
        let motion = !HQMotion.reduced
        let height = notice.bounds.height
        UIView.animate(withDuration: up ? 0.3 : 0.2, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
            notice.alpha = 0
            if motion && up { notice.transform = CGAffineTransform(translationX: 0, y: -(notice.resting.y + height)) }
            else if motion { notice.transform = CGAffineTransform(scaleX: 0.96, y: 0.96) }
            notice.materialize(false)
        } completion: { _ in notice.removeFromSuperview() }
    }

    /// The capsule: glass, the bot's face, the words (up to two lines), and "Watch".
    final class NoticeView: UIVisualEffectView, UIGestureRecognizerDelegate {
        var onTap: (() -> Void)?
        var onDismiss: (() -> Void)?
        var onHold: ((Holder, Bool) -> Void)?
        var onSizeChange: (() -> Void)?
        var leaving = false
        var resting = CGPoint.zero
        let contentStack = UIStackView()
        private let face = UIImageView()
        private let initial = UILabel()
        private let message = UILabel()
        private let watch = UILabel()
        private var alert: Alert?
        private var voiceOverOn = false
        /// The finger that is down: where it landed (in the window), the farthest it got from there, and its last
        /// few places for the speed at the lift.
        private struct Touch {
            var start: CGPoint
            var travel: CGFloat = 0
            var samples: [(time: TimeInterval, y: CGFloat)]
        }
        private var touch: Touch?
        private let tracker = TouchTracker()
        /// A finger is on the capsule.
        var isTouched: Bool { touch != nil }
        private var touchMoved = Date.distantPast
        /// How long the finger on the capsule has been still (0 with no finger on it).
        var secondsSinceTouchMoved: TimeInterval { touch == nil ? 0 : Date().timeIntervalSince(touchMoved) }
        /// The system's own glass, untinted, as the bar's Back and ⋯ beside it.
        private let glass: UIGlassEffect = {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = true
            return glass
        }()
        private static let leading: CGFloat = 12
        private static let trailing: CGFloat = 18

        init() {
            super.init(effect: nil)
            cornerConfiguration = .capsule()
            isAccessibilityElement = true
            accessibilityTraits = [.button]
            accessibilityIdentifier = "presence-notice"
            // The words grow with the text size, up to the first accessibility size (the capsule is a banner, not a page).
            maximumContentSizeCategory = .accessibilityMedium

            face.contentMode = .scaleAspectFill
            face.clipsToBounds = true
            face.layer.cornerRadius = 20
            face.layer.cornerCurve = .continuous
            initial.font = HQFont.system(ofSize: 16, weight: .semibold)
            initial.textColor = .white
            initial.textAlignment = .center
            initial.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
            face.addSubview(initial)
            face.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([face.widthAnchor.constraint(equalToConstant: 40), face.heightAnchor.constraint(equalToConstant: 40)])

            message.textColor = .label   // system-ink-ok: on the system's untinted glass
            message.numberOfLines = 2
            message.lineBreakMode = .byTruncatingTail
            message.setContentHuggingPriority(.defaultLow, for: .horizontal)
            message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            watch.text = "Watch"
            watch.textColor = HQPalette.tint
            watch.setContentHuggingPriority(.required, for: .horizontal)
            watch.setContentCompressionResistancePriority(.required, for: .horizontal)   // never truncated
            applyTextSize()

            contentStack.addArrangedSubview(face)
            contentStack.addArrangedSubview(message)
            contentStack.addArrangedSubview(watch)
            contentStack.axis = .horizontal
            contentStack.alignment = .center
            contentStack.spacing = 10
            contentStack.setCustomSpacing(Self.beforeWatch, after: message)
            contentStack.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(contentStack)
            NSLayoutConstraint.activate([
                contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.leading),
                contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Self.trailing),
                contentStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            ])

            // One recognizer, one finger, from the moment it lands (so a finger that rests on the capsule holds it)
            // to the moment it lifts. It reports straight to the three methods below, in order, and always finishes
            // a touch it began: there are no two recognizers whose callbacks could arrive out of step.
            tracker.delegate = self
            tracker.onBegan = { [weak self] point, time in self?.touchBegan(at: point, time: time) }
            tracker.onMoved = { [weak self] point, time in self?.touchMoved(to: point, time: time) }
            tracker.onEnded = { [weak self] point, time, cancelled in self?.touchEnded(at: point, time: time, cancelled: cancelled) }
            addGestureRecognizer(tracker)

            registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: NoticeView, _) in view.onSizeChange?() }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        private static let beforeWatch: CGFloat = 12

        func materialize(_ on: Bool) { effect = on ? glass : nil }

        /// 15 pt semibold at the default size, scaling with Dynamic Type (capped by `maximumContentSizeCategory`); at
        /// accessibility sizes the face steps aside to leave the words their room.
        func applyTextSize() {
            let base = HQFont.system(ofSize: 15, weight: .semibold)
            let scaled = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: base, compatibleWith: traitCollection)
            message.font = scaled
            watch.font = scaled
            face.isHidden = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        }

        /// The room the words have in a capsule this wide: what the face and "Watch" leave.
        func wordsWidth(forWidth width: CGFloat) -> CGFloat {
            let faceRoom: CGFloat = face.isHidden ? 0 : 40 + contentStack.spacing
            let watchRoom = ceil(watch.intrinsicContentSize.width) + Self.beforeWatch
            return max(0, width - Self.leading - Self.trailing - faceRoom - watchRoom)
        }

        /// A name too long for two lines is shortened, so "is using its browser" always shows.
        func fitWords(forWidth width: CGFloat) {
            guard let alert, let font = message.font else { return }
            message.text = PresenceNotice.fitted(name: alert.name, kind: alert.kind, font: font,
                                                 width: wordsWidth(forWidth: width), lines: message.numberOfLines)
        }

        /// The words on the capsule right now.
        var shownWords: String { message.text ?? "" }

        /// The height the words need at this capsule width (the face is 40).
        func contentHeight(forWidth width: CGFloat) -> CGFloat {
            let inner = max(0, width - Self.leading - Self.trailing)
            let fitted = contentStack.systemLayoutSizeFitting(CGSize(width: inner, height: UIView.layoutFittingCompressedSize.height),
                                                              withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
            return fitted.height
        }

        func fill(_ alert: Alert) {
            self.alert = alert
            message.text = alert.drawn
            if bounds.width > 0 { fitWords(forWidth: bounds.width) }
            if let shown = alert.face {
                face.image = shown.image; face.backgroundColor = .clear; initial.isHidden = true
                face.layer.cornerRadius = shown.isPhoto ? 0 : 20
            } else {
                face.image = nil
                face.layer.cornerRadius = 20
                face.backgroundColor = .systemGray
                initial.text = alert.name.first.map { String($0).uppercased() }
                initial.isHidden = false
            }
            accessibilityLabel = alert.message
            accessibilityHint = alert.hint
            accessibilityValue = "Watch"
        }

        override func accessibilityActivate() -> Bool { onTap?(); return true }
        override func accessibilityPerformEscape() -> Bool { onDismiss?(); return true }

        // VoiceOver's cursor on it holds it, like a finger.
        override func accessibilityElementDidBecomeFocused() {
            super.accessibilityElementDidBecomeFocused()
            if !voiceOverOn { voiceOverOn = true; onHold?(.voiceOver, true) }
        }

        override func accessibilityElementDidLoseFocus() {
            super.accessibilityElementDidLoseFocus()
            if voiceOverOn { voiceOverOn = false; onHold?(.voiceOver, false) }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        // MARK: The finger. Points are in the window's coordinates, times are the touch's own (so events that are
        // delivered late, in a batch, after a stall still give the true distance and speed).

        func touchBegan(at point: CGPoint, time: TimeInterval) {
            guard !leaving else { return }
            touch = Touch(start: point, samples: [(time, point.y)])
            touchMoved = Date()
            onHold?(.touch, true)
        }

        /// Up follows the finger; down only gives a little, as a banner does.
        func touchMoved(to point: CGPoint, time: TimeInterval) {
            guard !leaving, var now = touch else { return }
            now.travel = max(now.travel, hypot(point.x - now.start.x, point.y - now.start.y))
            now.samples.append((time, point.y))
            if now.samples.count > 8 { now.samples.removeFirst(now.samples.count - 8) }
            touch = now
            touchMoved = Date()
            let rise = point.y - now.start.y
            transform = CGAffineTransform(translationX: 0, y: rise < 0 ? rise : rise * 0.2)
        }

        /// The one place a touch is judged. Whatever it was, the finger's hold ends here, first.
        func touchEnded(at point: CGPoint, time: TimeInterval, cancelled: Bool) {
            guard var done = touch else { return }
            touch = nil
            onHold?(.touch, false)
            guard !leaving else { return }
            done.travel = max(done.travel, hypot(point.x - done.start.x, point.y - done.start.y))
            done.samples.append((time, point.y))
            let outcome = cancelled ? TouchOutcome.settle
                : PresenceNotice.outcome(travel: done.travel, rise: point.y - done.start.y, speed: Self.speed(done.samples))
            AppLog.note("presence", "notice touch: \(cancelled ? "cancelled" : "\(outcome)") (moved \(Int(done.travel)), rise \(Int(point.y - done.start.y)))")
            switch outcome {
            case .tap: settle(); onTap?()
            case .dismiss: onDismiss?()
            case .settle: settle()
            }
        }

        /// Vertical speed over the touch's last tenth of a second.
        private static func speed(_ samples: [(time: TimeInterval, y: CGFloat)]) -> CGFloat {
            guard let last = samples.last, let first = samples.first(where: { last.time - $0.time <= 0.1 }),
                  last.time - first.time > 0.001 else { return 0 }
            return (last.y - first.y) / CGFloat(last.time - first.time)
        }

        private func settle() {
            guard transform != .identity else { return }
            if HQMotion.reduced { transform = .identity; return }
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) { self.transform = .identity }
        }
    }

    /// Follows one finger on the capsule from down to up and says so, in order: began, moved…, then ended exactly
    /// once (as cancelled when the system takes the touch away or resets the recognizer mid-touch). It neither blocks
    /// nor is blocked by any other recognizer.
    final class TouchTracker: UIGestureRecognizer {
        var onBegan: ((CGPoint, TimeInterval) -> Void)?
        var onMoved: ((CGPoint, TimeInterval) -> Void)?
        var onEnded: ((CGPoint, TimeInterval, Bool) -> Void)?
        private var finger: UITouch?
        private var last = CGPoint.zero
        private var lastTime: TimeInterval = 0

        init() {
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        private func place(_ touch: UITouch) -> CGPoint {
            last = touch.location(in: view?.window)
            lastTime = touch.timestamp
            return last
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            // The newest finger is the one that counts. One that was never reported up (seen in stress round 1: the
            // lift of a touch made while the app was stopped never arrived) must not make the capsule deaf to the next.
            guard let touch = touches.first(where: { $0 !== finger }) else { return }
            for other in touches where other !== touch && other !== finger { ignore(other, for: event) }
            if let stale = finger {
                finish(at: last, time: lastTime, cancelled: true)
                ignore(stale, for: event)
            }
            finger = touch
            state = state == .possible ? .began : .changed
            onBegan?(place(touch), touch.timestamp)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let finger, touches.contains(finger) else { return }
            state = .changed
            onMoved?(place(finger), finger.timestamp)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let finger, touches.contains(finger) else { return }
            finish(at: place(finger), time: finger.timestamp, cancelled: false)
            state = .ended
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let finger, touches.contains(finger) else { return }
            finish(at: place(finger), time: finger.timestamp, cancelled: true)
            state = .cancelled
        }

        /// The system is done with this touch sequence. A finger that was never reported up is let go here.
        override func reset() {
            super.reset()
            if finger != nil { finish(at: last, time: lastTime, cancelled: true) }
        }

        private func finish(at point: CGPoint, time: TimeInterval, cancelled: Bool) {
            guard finger != nil else { return }
            finger = nil
            onEnded?(point, time, cancelled)
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    }
}
