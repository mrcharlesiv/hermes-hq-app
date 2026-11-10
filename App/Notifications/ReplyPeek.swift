// The in-app counterpart of a notification banner (port of the web app's DispatchReplyPeek, HermesUIChat.swift, build
// 222+): another chat's finished reply drops in as a Liquid Glass capsule — the system's own untinted glass — just under
// the Dynamic Island, with the bot's face, name and first line. The whole capsule opens the chat; a swipe up sends it
// away (on the Mac also its ✕); a finger (on the Mac, the pointer) resting on it holds it; it leaves by itself after
// 4.5 s (twice that with VoiceOver). A second reply
// while it shows takes its place and counts the others ("+1"), so replies never stack up over the chat.

import UIKit

struct PeekAlert {
    var name: String
    var body: String
    /// The chat a tap opens (stored id) and its bot.
    var session: String
    var profile: String?
    /// [photoheads] The face and whether it is the bot's photo (drawn as an app-icon tile, never cut to a circle).
    var face: BotFaces.Face?
}

@MainActor final class ReplyPeek: NSObject {
    static let shared = ReplyPeek()
    static let height: CGFloat = 64
    static let shownFor: TimeInterval = 4.5

    private(set) var view: PeekView?
    private var timer: Timer?
    private var target = ""
    private var others = 0
    private var open: ((PeekAlert) -> Void)?
    private var current: PeekAlert?

    var isShowing: Bool { view != nil }

    func show(_ alert: PeekAlert, in window: UIWindow, open: @escaping (PeekAlert) -> Void) {
        self.open = open
        let replacing = view != nil && view?.window === window && view?.leaving == false
        others = replacing ? (target == alert.session ? others : others + 1) : 0
        target = alert.session
        current = alert
        let peek = replacing ? view! : makeView(in: window)
        peek.fill(alert, others: others)
        layout(peek, in: window)
        if replacing {
            UIView.transition(with: peek.contentStack, duration: 0.2, options: .transitionCrossDissolve) {}   // motion-ok: cross-fade
        } else {
            appear(peek)
        }
        HQAnnounce.say(peek.accessibilityLabel, priority: .high)
        // [mac] A reply that takes the place of one under the pointer stays held until the pointer leaves.
        if peek.hovering { timer?.invalidate() } else { restartTimer() }
    }

    private func makeView(in window: UIWindow) -> PeekView {
        let peek = PeekView()
        peek.onTap = { [weak self] in
            guard let self, let alert = self.current else { return }
            Haptics.play(.light)
            self.dismiss(up: false)
            self.open?(alert)
        }
        peek.onDismiss = { [weak self] in self?.dismiss(up: true) }
        peek.onHold = { [weak self] holding in holding ? self?.timer?.invalidate() : self?.restartTimer() }
        window.addSubview(peek)
        view = peek
        return peek
    }

    private func layout(_ peek: PeekView, in window: UIWindow) {
        let inset: CGFloat = 12
        let width = min(window.bounds.width - inset * 2 - window.safeAreaInsets.left - window.safeAreaInsets.right, 440)
        // Apple's banner spot: just under the status bar and the Dynamic Island.
        let y = window.safeAreaInsets.top + 2
        // [a11y] The capsule grows with its (capped) text: the web's is fixed, native follows the text size.
        let height = max(Self.height, peek.wordsHeight + 16)
        peek.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        peek.center = CGPoint(x: window.bounds.midX, y: y + height / 2)
        peek.resting = peek.center
        peek.layoutIfNeeded()
    }

    private func appear(_ peek: PeekView) {
        peek.materialize(false)
        if HQMotion.reduced {
            peek.alpha = 0
            peek.materialize(true)
            UIView.animate(withDuration: 0.2) { peek.alpha = 1 }
            return
        }
        peek.alpha = 0
        peek.transform = CGAffineTransform(translationX: 0, y: -24).scaledBy(x: 0.9, y: 0.9)
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0.4) {   // motion-ok: Reduce Motion returned above (fade only)
            peek.alpha = 1
            peek.transform = .identity
            peek.materialize(true)
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        var shown = HQAccessibility.voiceOver ? Self.shownFor * 2 : Self.shownFor
        #if DEBUG
        // UI tests read the capsule before it leaves.
        if UserDefaults.standard.bool(forKey: "HQDebugPeekHold") { shown = 60 }
        #endif
        timer = Timer.scheduledTimer(withTimeInterval: shown, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(up: true) }
        }
    }

    func dismiss(up: Bool) {
        timer?.invalidate(); timer = nil
        guard let peek = view, !peek.leaving else { return }
        peek.leaving = true
        view = nil
        others = 0
        current = nil
        let motion = !HQMotion.reduced
        UIView.animate(withDuration: up ? 0.3 : 0.2, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
            peek.alpha = 0
            if motion && up { peek.transform = CGAffineTransform(translationX: 0, y: -(peek.resting.y + peek.bounds.height)) }
            else if motion { peek.transform = CGAffineTransform(scaleX: 0.96, y: 0.96) }
            peek.materialize(false)
        } completion: { _ in peek.removeFromSuperview() }
    }

    /// The capsule: glass, a face, a name over one line of the reply, and the others' count at the end.
    final class PeekView: UIVisualEffectView, UIGestureRecognizerDelegate {
        var onTap: (() -> Void)?
        var onDismiss: (() -> Void)?
        var onHold: ((Bool) -> Void)?
        var leaving = false
        var resting = CGPoint.zero
        let contentStack = UIStackView()
        private let face = UIImageView()
        private let initial = UILabel()
        private let name = UILabel()
        private let line = UILabel()
        private let count = UILabel()
        /// [mac] Mac stress #44: with a mouse the swipe up is hidden knowledge, so a small ✕ puts the capsule away, and
        /// the pointer resting on it holds it as a finger does. iPhone and iPad keep the swipe alone.
        private(set) var close: UIButton?
        private(set) var hovering = false
        /// The system's own glass, untinted, as the bar's Back and ⋯ beside it.
        private let glass: UIGlassEffect = {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = true
            return glass
        }()

        init() {
            super.init(effect: nil)
            cornerConfiguration = .capsule()
            isAccessibilityElement = true
            accessibilityTraits = [.button]
            accessibilityHint = "Opens the chat"
            accessibilityIdentifier = "reply-peek"

            face.contentMode = .scaleAspectFill
            face.clipsToBounds = true
            face.layer.cornerRadius = 20
            face.layer.cornerCurve = .continuous
            initial.font = HQFont.system(ofSize: 16, weight: .semibold) // a11y-font-ok: the letter inside the 40 pt face
            initial.accessibilityIdentifier = "reply-peek.initial"
            initial.textColor = .white
            initial.textAlignment = .center
            face.addSubview(initial)
            face.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([face.widthAnchor.constraint(equalToConstant: 40), face.heightAnchor.constraint(equalToConstant: 40)])

            name.font = HQFont.scaled(15, weight: .semibold, like: .subheadline, cap: 22)
            name.adjustsFontForContentSizeCategory = true   // [a11y] follows a live text-size change
            name.textColor = .label   // system-ink-ok: on the system's untinted glass
            line.font = HQFont.scaled(14, like: .footnote, cap: 22)
            line.adjustsFontForContentSizeCategory = true   // [a11y] follows a live text-size change
            line.textColor = .secondaryLabel   // system-ink-ok: on the system's untinted glass
            let words = UIStackView(arrangedSubviews: [name, line])
            words.axis = .vertical
            words.spacing = 1
            [name, line].forEach { $0.lineBreakMode = .byTruncatingTail }

            count.font = HQFont.scaled(13, weight: .semibold, like: .footnote, cap: 20)
            count.adjustsFontForContentSizeCategory = true   // [a11y] follows a live text-size change
            count.textColor = .secondaryLabel   // system-ink-ok: on the system's untinted glass
            count.setContentHuggingPriority(.required, for: .horizontal)
            count.setContentCompressionResistancePriority(.required, for: .horizontal)

            contentStack.addArrangedSubview(face)
            contentStack.addArrangedSubview(words)
            contentStack.addArrangedSubview(count)
            if DeviceWord.isMac {
                var config = UIButton.Configuration.plain()
                config.image = UIImage(systemName: "xmark.circle.fill",
                                       withConfiguration: UIImage.SymbolConfiguration(textStyle: .body, scale: .medium))
                config.baseForegroundColor = .tertiaryLabel   // system-ink-ok: on the system's untinted glass
                config.contentInsets = .zero
                let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.onDismiss?() })
                button.accessibilityIdentifier = "reply-peek.close"
                button.toolTip = "Dismiss"
                button.setContentHuggingPriority(.required, for: .horizontal)
                button.setContentCompressionResistancePriority(.required, for: .horizontal)
                contentStack.addArrangedSubview(button)
                close = button
                addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
            }
            contentStack.axis = .horizontal
            contentStack.alignment = .center
            contentStack.spacing = 10
            contentStack.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(contentStack)
            NSLayoutConstraint.activate([
                contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
                contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: close == nil ? -18 : -12),
                contentStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            ])

            let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
            press.minimumPressDuration = 0
            press.allowableMovement = 12
            press.delegate = self
            addGestureRecognizer(press)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            pan.delegate = self
            addGestureRecognizer(pan)
            press.require(toFail: pan)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func materialize(_ on: Bool) { effect = on ? glass : nil }

        /// The name over the line, at the current text size.
        var wordsHeight: CGFloat { ceil(name.font.lineHeight) + (line.isHidden ? 0 : 1 + ceil(line.font.lineHeight)) }

        func fill(_ alert: PeekAlert, others: Int) {
            name.text = alert.name
            line.text = alert.body
            line.isHidden = alert.body.isEmpty
            count.text = others > 0 ? "+\(others)" : nil
            count.isHidden = others == 0
            if let shown = alert.face {
                face.image = shown.image; face.backgroundColor = .clear; initial.isHidden = true
                // [photoheads] A photo comes as an app-icon tile with its own corners: it is never cut to a circle.
                // What was drawn decides, not what the bot wears: a photo that was not ready comes as a head.
                face.layer.cornerRadius = shown.isPhoto ? 0 : 20
            } else {
                face.image = nil
                face.layer.cornerRadius = 20
                face.backgroundColor = .systemGray
                initial.text = alert.name.first.map { String($0).uppercased() }
                initial.isHidden = false
            }
            initial.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
            let more = others > 0 ? ", and \(others) more \(others == 1 ? "reply" : "replies")" : ""
            accessibilityLabel = alert.body.isEmpty ? "\(alert.name) replied\(more)" : "\(alert.name) replied: \(alert.body)\(more)"
            accessibilityValue = others > 0 ? "+\(others)" : nil
        }

        override func accessibilityActivate() -> Bool { onTap?(); return true }
        override func accessibilityPerformEscape() -> Bool { onDismiss?(); return true }
        // [a11y] The swipe up has no VoiceOver or Switch Control form: "Dismiss" as an action.
        override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
            get { [UIAccessibilityCustomAction(name: "Dismiss") { [weak self] _ in self?.onDismiss?(); return true }] }
            set {}
        }

        @objc private func pressed(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began: onHold?(true)
            case .ended:
                if !hovering { onHold?(false) }
                if bounds.contains(recognizer.location(in: self)) { onTap?() }
            case .cancelled, .failed: if !hovering { onHold?(false) }
            default: break
            }
        }

        /// [mac] The pointer over the capsule holds it; leaving starts the full time again.
        @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
            switch recognizer.state {
            case .began: hovering = true; onHold?(true)
            case .ended, .cancelled, .failed: hovering = false; onHold?(false)
            default: break
            }
        }

        /// [mac] A click on ✕ is the button's alone: the capsule's press would open the chat.
        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let close else { return true }
            return touch.view?.isDescendant(of: close) != true
        }

        /// Up sends it away; down only gives a little, as a banner does, and springs back.
        @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
            let moved = recognizer.translation(in: superview).y
            switch recognizer.state {
            case .began: onHold?(true)
            case .changed:
                transform = CGAffineTransform(translationX: 0, y: moved < 0 ? moved : moved * 0.2)
            case .ended, .cancelled:
                let speed = recognizer.velocity(in: superview).y
                if moved < -18 || speed < -300 { onDismiss?(); return }
                onHold?(false)
                HQMotion.spring(duration: 0.35, damping: 0.8, changes: { self.transform = .identity })
            default: break
            }
        }
    }
}
