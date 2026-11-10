// [offline] The reconnect notice on screen (docs/spec/3x-offline.md §5.1): one capsule of the system's own glass under
// the status bar, in the slot the reply peek uses, saying what `ReconnectBanner` decided. A status, not a control: no
// tap action; a swipe up hides it for the rest of this outage. A reply peek takes the slot while it shows and the
// notice returns after it.
//
// **DECISION** (review, spec §5.1): the notice is transient and the header's subtitle ("Reconnecting…", "Offline") is
// the lasting sign of an outage, as Telegram keeps "Connecting…" in the title and nothing else. A sentence stays
// `stay` seconds (6) and leaves by itself; it comes back only when it has something new to say (the cause is named,
// the network is lost, "Hermes HQ keeps trying"). While it shows it takes no touches at all: the bar buttons under it
// (the account, search and compose buttons, Back in a chat) work through it. The swipe up is a pan the window
// watches without holding any touch back. [mac] Mac stress #45: a mouse has no swipe, so on the Mac the capsule has a
// small ✕ that hides it as the swipe does; the ✕ is the only part that takes a click.

import UIKit

@MainActor final class ConnectionBanner {
    static let maxWidth: CGFloat = 440
    static let sideInset: CGFloat = 12
    static let verticalPadding: CGFloat = 13
    static let fade: TimeInterval = 0.2
    /// How long one sentence stays before it leaves by itself.
    static let stay: TimeInterval = 6
    /// The capsule's type stops growing here (the system's bars stop too); the sentence wraps instead of being cut.
    static let largestText = UIContentSizeCategory.accessibilityMedium

    private var view: BannerView?
    private(set) var text = ""
    /// Swiped away: quiet until the outage ends.
    private(set) var hiddenForOutage = false
    private var peekWatch: Timer?
    private weak var window: UIWindow?
    /// The sentence that had its time on screen and left by itself: it is not shown a second time in this outage.
    private var expired: String?
    private var stayTimer: Timer?
    private var swipe: BannerSwipe?
    /// DEBUG (`-HQDebugNoticeStay <seconds>`): UI tests that tap under the notice need it up for longer than 6 s.
    var stayOverride: TimeInterval?
    /// DEBUG (`-HQDebugExposeStatus`): every sentence put up (with the capsule's frame) and taken down, so a UI test
    /// reads when the notice showed from a record instead of trying to catch it by looking.
    var onShown: ((String, CGRect) -> Void)?
    var onGone: (() -> Void)?

    var isShowing: Bool { view != nil }

    /// A sentence to show (a new one replaces the one on show).
    func show(_ sentence: String, in window: UIWindow?) {
        text = sentence
        guard !hiddenForOutage, sentence != expired, let window else { return }
        self.window = window
        if let view, view.window === window {
            guard view.sentence != sentence else { return }
            view.fill(sentence)
            layout(view, in: window)
            UIView.transition(with: view, duration: Self.fade, options: .transitionCrossDissolve) {}   // motion-ok: cross-dissolve, nothing moves
            armStay(for: sentence)
            onGone?()
            onShown?(sentence, view.frame)
        } else {
            view?.removeFromSuperview()
            let banner = BannerView()
            banner.onClose = { [weak self] in self?.hideForOutage() }
            banner.fill(sentence)
            window.addSubview(banner)
            layout(banner, in: window)
            banner.alpha = 0
            view = banner
            UIView.animate(withDuration: Self.fade) { banner.alpha = ReplyPeek.shared.isShowing ? 0 : 1 }   // motion-ok: opacity only
            watchPeek()
            watchSwipe(in: window)
            armStay(for: sentence)
            onShown?(sentence, banner.frame)
        }
        HQAnnounce.say(sentence)
    }

    /// The outage ended (or the notice stopped): the capsule fades out and a swipe is forgotten.
    func clear() {
        text = ""
        hiddenForOutage = false
        expired = nil
        remove(up: false)
    }

    /// The sentence leaves by itself after `stay`; the header keeps saying the link is down.
    private func armStay(for sentence: String) {
        stayTimer?.invalidate()
        let timer = Timer(timeInterval: stayOverride ?? Self.stay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.view?.sentence == sentence else { return }
                self.expired = sentence
                self.remove(up: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        stayTimer = timer
    }

    /// The swipe up: a pan on the window that begins on the capsule and moves up. It holds no touch back.
    private func watchSwipe(in window: UIWindow) {
        unwatchSwipe()
        let swipe = BannerSwipe(frame: { [weak self] in self?.view?.frame }) { [weak self] in self?.hideForOutage() }
        window.addGestureRecognizer(swipe.recognizer)
        self.swipe = swipe
    }

    /// The swipe up (or the Mac's ✕): quiet until the outage ends.
    private func hideForOutage() {
        guard view != nil else { return }
        hiddenForOutage = true
        remove(up: true)
    }

    private func unwatchSwipe() {
        if let swipe { swipe.recognizer.view?.removeGestureRecognizer(swipe.recognizer) }
        swipe = nil
    }

    /// The app left the screen (sign-in, the offline screen): nothing shows; the sentence is kept for a return.
    func suspend() { remove(up: false) }

    /// The window changed size or the text size changed.
    func relayout() {
        guard let view, let window = view.window else { return }
        view.fill(view.sentence)
        layout(view, in: window)
    }

    private func remove(up: Bool) {
        peekWatch?.invalidate(); peekWatch = nil
        stayTimer?.invalidate(); stayTimer = nil
        unwatchSwipe()
        guard let banner = view else { return }
        view = nil
        onGone?()
        let motion = up && !HQMotion.reduced
        UIView.animate(withDuration: Self.fade, delay: 0, options: [.beginFromCurrentState, .curveEaseIn]) {
            banner.alpha = 0
            if motion { banner.transform = CGAffineTransform(translationX: 0, y: -(banner.frame.maxY + 8)) }
        } completion: { _ in banner.removeFromSuperview() }
    }

    private func layout(_ banner: BannerView, in window: UIWindow) {
        let safe = window.safeAreaInsets
        let width = min(window.bounds.width - Self.sideInset * 2 - safe.left - safe.right, Self.maxWidth)
        banner.transform = .identity
        banner.frame = CGRect(x: (window.bounds.width - width) / 2, y: safe.top + 2, width: width, height: banner.height(for: width))
        banner.layoutIfNeeded()
        banner.shape()
        window.bringSubviewToFront(banner)
    }

    /// The reply peek owns the slot while it shows.
    private func watchPeek() {
        peekWatch?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let banner = self.view else { return }
                let target: CGFloat = ReplyPeek.shared.isShowing ? 0 : 1
                guard banner.alpha != target, banner.layer.animationKeys()?.isEmpty ?? true else { return }
                UIView.animate(withDuration: Self.fade) { banner.alpha = target }   // motion-ok: opacity only
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        peekWatch = timer
    }

    /// The capsule: glass, a symbol, the sentence (whole, however many lines).
    final class BannerView: UIView {
        private(set) var sentence = ""
        private let glass: UIVisualEffectView = {
            let view = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
            view.cornerConfiguration = .capsule()
            return view
        }()
        private let symbol = UIImageView()
        private let label = UILabel()
        /// [mac] The ✕ (nil on iPhone and iPad, where the swipe up hides the notice).
        private(set) var close: UIButton?
        var onClose: (() -> Void)?
        static let closeSize: CGFloat = 22
        /// What the ✕ takes from the sentence's width: itself and its gap, less the plain trailing padding (0 without one).
        private var closeRoom: CGFloat { close == nil ? 0 : Self.closeSize + 8 + 12 - 18 }

        init() {
            super.init(frame: .zero)
            accessibilityIdentifier = "connection.banner"
            // A status, never in the way: every touch goes to what is under it (the bar's buttons). [mac] Only the ✕
            // takes a click (`hitTest`); the rest still passes through.
            isUserInteractionEnabled = DeviceWord.isMac
            isAccessibilityElement = true
            accessibilityTraits = .staticText
            glass.translatesAutoresizingMaskIntoConstraints = false
            addSubview(glass)
            symbol.translatesAutoresizingMaskIntoConstraints = false
            symbol.tintColor = HQPalette.label2
            symbol.contentMode = .scaleAspectFit
            symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: Self.font(), scale: .medium)
            symbol.setContentHuggingPriority(.required, for: .horizontal)
            symbol.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = Self.font()
            label.textColor = HQPalette.label
            // Stress round 1: the sentence is never cut. It wraps to as many lines as it needs, and the capsule's type
            // stops growing at the first accessibility size, as the system's own bars do, so it stays a notice and
            // not a wall (at the largest size it was 259 pt tall and still cut after four lines).
            label.numberOfLines = 0
            label.accessibilityIdentifier = "connection.banner.text"
            glass.contentView.addSubview(symbol)
            glass.contentView.addSubview(label)
            let padding = ConnectionBanner.verticalPadding
            var trailing = label.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -18)
            if DeviceWord.isMac {
                var config = UIButton.Configuration.plain()
                config.image = UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(textStyle: .body, scale: .medium))
                config.baseForegroundColor = HQPalette.label2
                config.contentInsets = .zero
                let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.onClose?() })
                button.accessibilityIdentifier = "connection.banner.close"
                button.toolTip = "Hide"
                button.translatesAutoresizingMaskIntoConstraints = false
                glass.contentView.addSubview(button)
                close = button
                trailing = label.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -8)
                NSLayoutConstraint.activate([
                    button.widthAnchor.constraint(equalToConstant: Self.closeSize),
                    button.heightAnchor.constraint(equalToConstant: Self.closeSize),
                    button.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -12),
                    button.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
                ])
            }
            NSLayoutConstraint.activate([
                glass.topAnchor.constraint(equalTo: topAnchor),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor),
                glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                symbol.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 18),
                symbol.centerYAnchor.constraint(equalTo: label.centerYAnchor),
                label.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 10),
                trailing,
                label.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: padding),
                label.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -padding),
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// [mac] The ✕ (with a little slack round it) is the only part that takes a click.
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard let close, alpha > 0.01 else { return nil }
            return close.bounds.insetBy(dx: -6, dy: -6).contains(close.convert(point, from: self)) ? close : nil
        }

        /// The notice's type: the subheadline at the user's text size, up to the first accessibility size.
        static func font(at chosen: UIContentSizeCategory = UIApplication.shared.preferredContentSizeCategory) -> UIFont {
            let size = chosen > ConnectionBanner.largestText ? ConnectionBanner.largestText : chosen
            return HQFont.preferred(.subheadline, compatibleWith: UITraitCollection(preferredContentSizeCategory: size))
        }

        func fill(_ text: String) {
            label.font = Self.font()
            symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: label.font, scale: .medium)
            sentence = text
            label.text = text
            symbol.image = UIImage(systemName: ReconnectNotice.symbol(for: text))
            accessibilityLabel = text
        }

        /// The capsule's height at `width`: the sentence wrapped (whole, however many lines) plus the padding. The label is told
        /// its width first; without it a label measures itself as one line and the sentence would be cut.
        func height(for width: CGFloat) -> CGFloat {
            let symbolWidth = ceil(symbol.intrinsicContentSize.width)
            let textWidth = max(60, width - 18 - symbolWidth - 10 - 18 - closeRoom)
            label.preferredMaxLayoutWidth = textWidth
            let text = label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
            return ceil(text.height) + ConnectionBanner.verticalPadding * 2
        }

        /// One line is a capsule; a wrapped sentence gets 22 pt continuous corners.
        func shape() {
            let oneLine = label.font.lineHeight * 1.5
            glass.cornerConfiguration = label.bounds.height <= oneLine ? .capsule() : .corners(radius: .fixed(22))
        }
    }
}

/// The swipe that puts the notice away: a pan on the window that begins on the capsule and moves up. It recognises
/// beside everything else and cancels no touch, so a tap or a scroll that starts on the capsule still reaches the bar.
@MainActor private final class BannerSwipe: NSObject, UIGestureRecognizerDelegate {
    let recognizer = UIPanGestureRecognizer()
    private let frame: @MainActor () -> CGRect?
    private let swiped: @MainActor () -> Void

    init(frame: @escaping @MainActor () -> CGRect?, swiped: @escaping @MainActor () -> Void) {
        self.frame = frame
        self.swiped = swiped
        super.init()
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = self
        recognizer.addTarget(self, action: #selector(panned(_:)))
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer, let view = pan.view, let frame = frame() else { return false }
        let velocity = pan.velocity(in: view), moved = pan.translation(in: view), now = pan.location(in: view)
        let start = CGPoint(x: now.x - moved.x, y: now.y - moved.y)
        return frame.insetBy(dx: -8, dy: -8).contains(start) && velocity.y < 0 && abs(velocity.y) > abs(velocity.x)
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began { swiped() }
    }
}
