// The away pill (docs/spec/3x-talk.md §6.6, row L536): a 44 pt glass capsule that floats over whatever screen is in
// front while a conversation runs in a chat that is not, or while a paused / stopped notice waits in one. A tap leads
// back to that chat; End ends the conversation from anywhere. Hosted in a pass-through overlay on the signed-in
// root, so sheets cover it and every pushed screen keeps it (DECISION T11: it floats; it is not the tab bar's
// accessory).

import UIKit

/// A screen says where its bottom chrome begins, in window coordinates; the pill rests 8 pt above it.
@MainActor protocol TalkPillAnchoring: AnyObject {
    var talkPillBottomInWindow: CGFloat { get }
}

/// What the pill shows. Pure, so the wording is tested without a view.
nonisolated enum TalkPillContent: Equatable, Sendable {
    /// `problem`: a turn failed since the person left the chat.
    case live(label: String, problem: Bool)
    case notice(kind: TalkNotice.Kind, label: String)

    var label: String {
        switch self {
        case .live(let label, _), .notice(_, let label): label
        }
    }

    /// What VoiceOver reads for the capsule.
    var spoken: String {
        switch self {
        case .live(let label, false): "\(label). Return to the conversation"
        case .live(let label, true): "\(label). Voice had a problem. Return to the conversation"
        case .notice(_, let label): "\(label). Opens the chat"
        }
    }

    var showsEnd: Bool { if case .live = self { true } else { false } }
}

@MainActor final class TalkAwayPill: UIView {
    /// Posted when the pill shows, hides or moves (the Bots list keeps its last rows clear of it).
    static let changed = Notification.Name("hq.talk.pill.changed")
    static let height: CGFloat = 44
    /// How much of a list the pill covers, with its gap: screens under it add this much bottom inset.
    static let clearance: CGFloat = 52

    private(set) static weak var current: TalkAwayPill?
    static var isShowing: Bool { current?.shown != nil }
    static var frameInWindow: CGRect {
        guard let pill = current, pill.shown != nil, let window = pill.window else { return .null }
        return pill.capsule.convert(pill.capsule.bounds, to: window)
    }

    /// A screen's bottom chrome moved (a keyboard, a queue card): the pill follows inside the same layout pass.
    static func anchorChanged() {
        guard let pill = current, pill.shown != nil else { return }
        pill.place(animated: false)
    }

    /// Puts the overlay on the signed-in root. Called again for a new root (a new sign-in).
    static func attach(to root: UIViewController) {
        current?.detach()
        let pill = TalkAwayPill(root: root)
        pill.frame = root.view.bounds
        pill.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.view.addSubview(pill)
        current = pill
        pill.refresh()
    }

    /// Opens the chat a conversation or a notice lives in (set by `TalkWiring`).
    var onOpen: (() -> Void)?

    private weak var root: UIViewController?
    private let capsule = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let dot = UIView()
    private let glyph = UIImageView()
    private let label = UILabel()
    private let open = UIControl()
    private let endButton = UIButton(type: .system)
    private let row = UIStackView()
    private var shown: TalkPillContent?
    private var wanted: TalkPillContent?
    private var appear: Timer?
    private var watch: Timer?
    private var bottom: CGFloat = 0
    private var observers: [any NSObjectProtocol] = []

    private init(root: UIViewController) {
        self.root = root
        super.init(frame: .zero)
        isAccessibilityElement = false
        capsule.cornerConfiguration = .capsule()
        capsule.alpha = 0
        capsule.isHidden = true
        addSubview(capsule)

        dot.backgroundColor = .systemGreen
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        glyph.contentMode = .center
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: HQFont.monoDigit(ofSize: 15, weight: .semibold), maximumPointSize: 22)
        label.adjustsFontForContentSizeCategory = true
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let lead = UIView()
        lead.translatesAutoresizingMaskIntoConstraints = false
        lead.addSubview(dot)
        lead.addSubview(glyph)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            lead.widthAnchor.constraint(equalToConstant: 20),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.centerXAnchor.constraint(equalTo: lead.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: lead.centerYAnchor),
            glyph.centerXAnchor.constraint(equalTo: lead.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: lead.centerYAnchor),
        ])
        let words = UIStackView(arrangedSubviews: [lead, label])
        words.axis = .horizontal
        words.spacing = 6
        words.alignment = .center
        words.isUserInteractionEnabled = false
        words.translatesAutoresizingMaskIntoConstraints = false
        // The capsule's own tap target: everything but End.
        open.addSubview(words)
        open.accessibilityIdentifier = "talk.pill"
        open.isAccessibilityElement = true
        open.accessibilityTraits = .button
        open.addTarget(self, action: #selector(openTapped), for: .touchUpInside)
        NSLayoutConstraint.activate([
            words.leadingAnchor.constraint(equalTo: open.leadingAnchor, constant: 14),
            words.trailingAnchor.constraint(equalTo: open.trailingAnchor, constant: -4),
            words.centerYAnchor.constraint(equalTo: open.centerYAnchor),
        ])

        var end = UIButton.Configuration.plain()
        end.title = "End"
        // The tint, as the bar's End capsule in the chat: the same action looks the same on every screen.
        end.baseForegroundColor = ChatPalette.tint
        end.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 16)
        end.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: HQFont.system(ofSize: 15, weight: .semibold), maximumPointSize: 22)
            return outgoing
        }
        endButton.configuration = end
        endButton.accessibilityIdentifier = "talk.pill.end"
        endButton.accessibilityLabel = "End Voice Conversation"
        endButton.addTarget(self, action: #selector(endTapped), for: .touchUpInside)
        endButton.setContentHuggingPriority(.required, for: .horizontal)
        endButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        row.axis = .horizontal
        row.alignment = .fill
        row.addArrangedSubview(open)
        row.addArrangedSubview(endButton)
        row.translatesAutoresizingMaskIntoConstraints = false
        capsule.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: capsule.contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: capsule.contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: capsule.contentView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: capsule.contentView.trailingAnchor),
        ])

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: TalkController.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func detach() {
        appear?.invalidate()
        watch?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        removeFromSuperview()
    }

    // Only the capsule takes touches; everything else falls through to the screen underneath.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard shown != nil, !capsule.isHidden, capsule.alpha > 0.5, capsule.frame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if shown != nil { place(animated: false) }
    }

    // MARK: Content

    private func refresh() {
        let next = TalkController.shared.pillContent
        guard next != wanted else { return }
        wanted = next
        appear?.invalidate()
        appear = nil
        guard let next else { hide(); return }
        if shown != nil {
            show(next)
            return
        }
        // 250 ms after the chat left the screen, so a quick back-and-forth does not flash it.
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let content = self.wanted else { return }
                self.show(content)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        appear = timer
    }

    private func show(_ content: TalkPillContent) {
        let first = shown == nil
        shown = content
        label.text = content.label
        open.accessibilityLabel = content.spoken
        endButton.isHidden = !content.showsEnd
        switch content {
        case .live(_, let problem):
            dot.isHidden = problem
            glyph.isHidden = !problem
            // The glyphs grow with the words (Subheadline, capped at 22) up to the same cap.
            glyph.image = UIImage(systemName: "exclamationmark.triangle.fill",
                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: HQFont.symbolSize(15, like: .subheadline, cap: 22), weight: .semibold))
            glyph.tintColor = .systemOrange
            label.textColor = .label   // system-ink-ok: words on the pill's system glass
        case .notice(let kind, _):
            dot.isHidden = true
            glyph.isHidden = false
            let paused = kind == .paused
            glyph.image = UIImage(systemName: paused ? "pause.circle.fill" : "exclamationmark.triangle.fill",
                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: HQFont.symbolSize(17, like: .subheadline, cap: 24), weight: .semibold))
            glyph.tintColor = paused ? .systemOrange : .systemRed
            // The glyph carries the warning colour; orange or red words on light glass are too faint to read.
            label.textColor = .label   // system-ink-ok: words on the pill's system glass
        }
        superview?.bringSubviewToFront(self)
        if first {
            capsule.isHidden = false
            place(animated: false)
            let reduce = HQMotion.reduced
            capsule.alpha = 0
            capsule.transform = reduce ? .identity : CGAffineTransform(translationX: 0, y: 18)
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]) {
                self.capsule.alpha = 1
                self.capsule.transform = .identity
            }
            startWatching()
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        } else {
            place(animated: false)
        }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    private func hide() {
        guard shown != nil else { return }
        shown = nil
        watch?.invalidate()
        watch = nil
        let reduce = HQMotion.reduced
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
            self.capsule.alpha = 0
            if !reduce { self.capsule.transform = CGAffineTransform(translationX: 0, y: 18) }
        } completion: { _ in
            guard self.shown == nil else { return }
            self.capsule.isHidden = true
            self.capsule.transform = .identity
        }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    // MARK: Place

    /// The screen in front may change under the pill without telling it (a push, a tab switch): it looks four times a
    /// second while it shows, and a chat tells it at once through `anchorChanged()`.
    private func startWatching() {
        watch?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.shown != nil else { return }
                let edge = self.anchor()
                if abs(edge - self.bottom) > 0.5 { self.place(animated: true) }
                self.superview?.bringSubviewToFront(self)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }

    /// The top of the front screen's bottom chrome, in this view's coordinates.
    private func anchor() -> CGFloat {
        guard let root, let window else { return bounds.maxY - safeAreaInsets.bottom }
        var front: UIViewController = root
        if let tabs = root as? UITabBarController, let selected = tabs.selectedViewController { front = selected }
        if let navigation = front as? UINavigationController, let top = navigation.topViewController { front = top }
        if let anchoring = front as? any TalkPillAnchoring, front.viewIfLoaded?.window != nil {
            return convert(CGPoint(x: 0, y: anchoring.talkPillBottomInWindow), from: window).y
        }
        #if targetEnvironment(macCatalyst)
        // [mac] The app's own glass bar stands in for the system's (DesktopTabBar). The pill is centred on the window, so
        // only a bar under its middle lifts it: one pane, not the list column beside a chat.
        if let docked = AppRoot.tabs(window)?.view.subviews.last(where: { $0 is DesktopTabBar }) as? DesktopTabBar,
           !docked.isHidden, !docked.coveredByPage, docked.alpha > 0.01 {
            let bar = docked.convert(docked.bounds, to: self)
            if bar.minY < bounds.maxY - 1, bar.maxX > bounds.midX - 100, bar.minX < bounds.midX + 100 { return bar.minY }
        }
        #endif
        if let tabs = root as? UITabBarController, !tabs.tabBar.isHidden, tabs.tabBar.window != nil, tabs.tabBar.alpha > 0.01,
           !front.hidesBottomBarWhenPushed {
            let bar = tabs.tabBar.convert(tabs.tabBar.bounds, to: self)
            if bar.minY < bounds.maxY - 1 { return bar.minY }
        }
        return bounds.maxY - safeAreaInsets.bottom
    }

    private func place(animated: Bool) {
        bottom = anchor()
        let limit = max(120, bounds.width - 32)
        let fit = row.systemLayoutSizeFitting(CGSize(width: limit, height: Self.height), withHorizontalFittingPriority: .fittingSizeLevel,
                                              verticalFittingPriority: .required)
        let width = min(limit, max(160, ceil(fit.width)))
        let frame = CGRect(x: ((bounds.width - width) / 2).rounded(), y: bottom - 8 - Self.height, width: width, height: Self.height)
        let transform = capsule.transform
        let apply = {
            self.capsule.transform = .identity
            self.capsule.frame = frame
            self.capsule.transform = transform
        }
        if animated, !HQMotion.reduced {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState], animations: apply)
        } else {
            apply()
        }
    }

    // MARK: Actions

    @objc private func openTapped() {
        Haptics.play(.selection)
        onOpen?()
    }

    @objc private func endTapped() {
        Haptics.play(.medium)
        TalkController.shared.end()
    }
}
