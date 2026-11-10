// What the transcript shows while it has no rows (spec 06 §4.2, spec 03 §4.7):
// - loading: a skeleton at the bottom of the transcript — one trailing 56 %-wide, 48 pt bubble and three leading 16 pt
//   lines in Fill 3 with a shimmer (never a spinner on white);
// - failed: the reason and Retry (the composer stays);
// - empty: the bot's intro — an 80 pt head, the name in Title 2 and a line under it; [talk] its role and description
//   when the bot has them, and two tinted capsules, Talk and Bot Info (docs/spec/3x-talk.md §5.6); under them, while the
//   chat has no name of its own, a plain Name Chat (owner 2026-10-30: "a shortcut here to name the session").

import UIKit

final class ChatPlaceholderView: UIView {
    enum Mode: Equatable {
        case loading
        case failed(String)
        case empty(name: String, head: JSONValue?, profile: String, intro: Intro = Intro())
        /// [settings] An empty chat with Intro Splash off: nothing drawn; VoiceOver still hears "No messages yet".
        case blank
    }

    /// [talk] What an empty chat adds under the name (docs/spec/3x-talk.md §5.6).
    struct Intro: Equatable {
        var role: String?
        var about: String?
        var talk = false
        var info = false
        /// Name Chat under the capsules: the chat can be renamed and is still "New Chat".
        var name = false

        /// The role shows only when it differs from the name; the description only when it differs from the role
        /// (`W:src/ui-bots/bot-intro.tsx`).
        static func lines(name: String, role: String?, about: String?) -> (role: String?, about: String?) {
            let title = (role ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let shownRole = !title.isEmpty && title.lowercased() != name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ? title : nil
            let text = (about ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (shownRole, !text.isEmpty && text != shownRole ? text : nil)
        }
    }

    var mode: Mode? { didSet { if mode != oldValue { apply() } } }
    var onRetry: (() -> Void)?
    // [talk] The intro's two capsules.
    var onTalk: (() -> Void)?
    var onInfo: (() -> Void)?
    /// Name Chat: the Rename Chat prompt, its field empty.
    var onName: (() -> Void)?
    private let roleLabel = UILabel()
    private let capsules = UIStackView()
    private let talkButton = UIButton(configuration: .tinted())
    private let infoButton = UIButton(configuration: .tinted())
    private let nameButton = UIButton(configuration: .plain())

    private let skeleton = UIView()
    private let bubble = UIView()
    private var lines: [UIView] = []
    private let shimmer = CAGradientLayer()
    private let stack = UIStackView()
    /// [backdrop] Under the intro on a chat background: a glass card, so the role and the grey words stay readable.
    private let card = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let head = HeadView(side: 80)
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let retryButton = UIButton(configuration: .hqPush())

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        backgroundColor = .clear
        addSubview(skeleton)
        skeleton.isUserInteractionEnabled = false
        for view in [bubble] + (0..<3).map({ _ in UIView() }) {
            view.backgroundColor = ChatPalette.fill3
            view.layer.cornerCurve = .continuous
            skeleton.addSubview(view)
            if view !== bubble { lines.append(view) }
        }
        lines.forEach { $0.layer.cornerRadius = 8 }
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.colors = [UIColor.black.withAlphaComponent(0.55).cgColor, UIColor.black.cgColor, UIColor.black.withAlphaComponent(0.55).cgColor]
        shimmer.locations = [0, 0.5, 1]
        skeleton.layer.mask = shimmer
        skeleton.isAccessibilityElement = true
        skeleton.accessibilityLabel = "Loading messages"
        skeleton.accessibilityTraits = .updatesFrequently

        card.isUserInteractionEnabled = false
        card.isHidden = true
        card.cornerConfiguration = .corners(radius: .fixed(24))
        addSubview(card)
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        addSubview(stack)
        head.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([head.widthAnchor.constraint(equalToConstant: 80), head.heightAnchor.constraint(equalToConstant: 80)])
        titleLabel.font = HQFont.preferred(.title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = ChatPalette.label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        bodyLabel.font = HQFont.preferred(.subheadline)
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.textColor = ChatPalette.label2
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0
        var retry = UIButton.Configuration.hqPush()
        retry.title = "Try Again"
        retry.image = UIImage(systemName: "arrow.clockwise")
        retry.imagePadding = 6
        retryButton.configuration = retry
        retryButton.accessibilityIdentifier = "chat.retry-open"
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)
        // [talk] The role under the name and the two capsules under the text.
        roleLabel.font = HQFont.preferred(.subheadline)
        roleLabel.adjustsFontForContentSizeCategory = true
        roleLabel.textColor = ChatPalette.label2
        roleLabel.textAlignment = .center
        roleLabel.numberOfLines = 2
        roleLabel.isHidden = true
        func capsule(_ button: UIButton, _ title: String, _ symbol: String, _ id: String, _ run: @escaping () -> Void) {
            var config = UIButton.Configuration.tinted()
            config.title = title
            // Body-sized (17 pt at the default size) and growing with the title, as a fixed 17 pt did not.
            config.image = UIImage(systemName: symbol)
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
                .applying(UIImage.SymbolConfiguration(weight: .medium))
            config.imagePadding = 6
            config.cornerStyle = .capsule
            config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: HQFont.system(ofSize: 15, weight: .semibold))
                return outgoing
            }
            button.configuration = config
            button.accessibilityIdentifier = id
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.addAction(UIAction { _ in run() }, for: .touchUpInside)
        }
        capsule(talkButton, "Talk", "waveform", "chat.intro.talk") { [weak self] in self?.onTalk?() }
        capsule(infoButton, "Bot Info", "info.circle", "chat.intro.info") { [weak self] in self?.onInfo?() }
        capsules.spacing = 10
        capsules.addArrangedSubview(talkButton)
        capsules.addArrangedSubview(infoButton)
        capsules.isHidden = true
        // Quieter than the capsules: tint text, no fill, the same 44 pt touch height.
        var name = UIButton.Configuration.plain()
        name.title = "Name Chat"
        name.image = UIImage(systemName: "pencil")
        name.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .subheadline)
            .applying(UIImage.SymbolConfiguration(weight: .medium))
        name.imagePadding = 5
        name.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        name.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: HQFont.system(ofSize: 15, weight: .medium))
            return outgoing
        }
        nameButton.configuration = name
        nameButton.accessibilityIdentifier = "chat.intro.name"
        // Its label is its title, so "Tap Name Chat" (Voice Control) finds it; the hint says what it names.
        nameButton.accessibilityHint = "Names this chat"
        nameButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        nameButton.addAction(UIAction { [weak self] _ in self?.onName?() }, for: .touchUpInside)
        nameButton.isHidden = true
        for view in [head, titleLabel, roleLabel, bodyLabel, capsules, nameButton, retryButton] as [UIView] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(16, after: head)
        stack.setCustomSpacing(4, after: titleLabel)
        stack.setCustomSpacing(16, after: bodyLabel)
        stack.setCustomSpacing(4, after: capsules)
        stack.setCustomSpacing(18, after: nameButton)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: ChatPlaceholderView, _) in view.setNeedsLayout() }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: ChatPlaceholderView, _) in view.arrangeCapsules() }
        arrangeCapsules()
        // [settings] Saving power stops the skeleton's shimmer; it starts again when saving ends (3x-settings §3).
        powerWatch = NotificationCenter.default.addObserver(forName: PowerState.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if HQMotion.decorativeStill { self.shimmer.removeAllAnimations() } else if self.mode == .loading, self.window != nil { self.startShimmer() }
            }
        }
    }

    private var powerWatch: NSObjectProtocol?
    /// [settings] Whether the skeleton's shimmer is running (tests).
    var isShimmering: Bool { shimmer.animation(forKey: "shimmer") != nil }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// What the intro left out to fit its room (see layoutSubviews), shown again before each fitting.
    private var squeezed: [UIView] = []

    private func apply() {
        unsqueeze()
        let loading = mode == .loading
        skeleton.isHidden = !loading
        stack.isHidden = loading || mode == nil || mode == .blank
        // [settings] Intro Splash off: the area is empty, but not silent.
        isAccessibilityElement = mode == .blank
        accessibilityLabel = mode == .blank ? "No messages yet" : nil
        accessibilityIdentifier = mode == .blank ? "chat.intro.off" : nil
        switch mode {
        case .failed(let reason):
            head.isHidden = true
            titleLabel.text = "Couldn’t Load This Chat"
            bodyLabel.text = reason
            bodyLabel.font = HQFont.preferred(.subheadline)
            bodyLabel.numberOfLines = 0
            retryButton.isHidden = false
            roleLabel.isHidden = true
            capsules.isHidden = true
            nameButton.isHidden = true
            stack.setCustomSpacing(10, after: titleLabel)
        case .empty(let name, let raw, let profile, let intro):
            head.isHidden = false
            head.configure(raw: raw, profile: profile)
            titleLabel.text = name
            retryButton.isHidden = true
            // [talk] Who the bot is, then the two ways to start (§5.6).
            let lines = Intro.lines(name: name, role: intro.role, about: intro.about)
            roleLabel.text = lines.role
            roleLabel.isHidden = lines.role == nil
            bodyLabel.text = lines.about ?? "No messages yet. Say hello."
            bodyLabel.font = HQFont.preferred(lines.about == nil ? .subheadline : .footnote)
            bodyLabel.numberOfLines = lines.about == nil ? 0 : 4
            stack.setCustomSpacing(lines.role == nil ? 10 : 4, after: titleLabel)
            talkButton.isHidden = !intro.talk
            talkButton.accessibilityLabel = "Talk with \(name)"
            infoButton.isHidden = !intro.info
            capsules.isHidden = !intro.talk && !intro.info
            nameButton.isHidden = !intro.name
        default:
            break
        }
        if loading { startShimmer() } else { shimmer.removeAllAnimations() }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = ChatMetrics.sideInset
        let column = bounds.width - 2 * side
        // The skeleton sits at the transcript's bottom, where the newest messages will be.
        let lineH: CGFloat = 16, lineGap: CGFloat = 10
        let widths: [CGFloat] = [0.78, 0.64, 0.4]
        var y = bounds.height
        for (i, line) in lines.enumerated().reversed() {
            y -= lineH
            line.frame = CGRect(x: side, y: y, width: (column * widths[i]).rounded(), height: lineH)
            if i > 0 { y -= lineGap }
        }
        y -= 18 + 48
        let bubbleW = (column * 0.56).rounded()
        bubble.frame = CGRect(x: bounds.width - side - bubbleW, y: y, width: bubbleW, height: 48)
        bubble.layer.cornerRadius = ChatMetrics.bubbleRadius   // here, not once: it follows Theme › Bubble Corners
        skeleton.frame = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shimmer.frame = CGRect(x: -bounds.width, y: 0, width: bounds.width * 3, height: bounds.height)
        CATransaction.commit()
        // Short of room (the keys up on a new chat, the Talk tip over the composer), the intro leaves out the face, then
        // the words about the bot, then its role, so its buttons stay above what's docked under it and take taps.
        unsqueeze()
        let fitting = { self.stack.systemLayoutSizeFitting(CGSize(width: column, height: UIView.layoutFittingCompressedSize.height),
                                                           withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel) }
        var fit = fitting()
        if case .empty = mode {
            for view in [head, bodyLabel, roleLabel] as [UIView] where fit.height > bounds.height && !view.isHidden {
                view.isHidden = true
                squeezed.append(view)
                fit = fitting()
            }
        }
        stack.frame = CGRect(x: side, y: max(0, ((bounds.height - fit.height) / 2 - 20).rounded()), width: column, height: fit.height.rounded(.up))
        placeCard()
        if mode == .loading, window != nil { startShimmer() }
    }

    private func unsqueeze() {
        squeezed.forEach { $0.isHidden = false }
        squeezed = []
    }

    /// [backdrop] The card hugs what the intro shows (the stack spans the column; its rows are centred in it), 20 pt
    /// around it. Only on a chat background: on the page the intro stays as it was.
    private func placeCard() {
        card.isHidden = stack.isHidden || !Backdrop.chats.shows
        guard !card.isHidden else { return }
        stack.layoutIfNeeded()
        let shown = stack.arrangedSubviews.filter { !$0.isHidden }.map(\.frame)
        guard let first = shown.first else { return card.isHidden = true }
        let content = shown.dropFirst().reduce(first) { $0.union($1) }.offsetBy(dx: stack.frame.minX, dy: stack.frame.minY)
        card.frame = content.insetBy(dx: -20, dy: -20).intersection(bounds.insetBy(dx: 8, dy: 0))
    }

    private func startShimmer() {
        guard !HQMotion.decorativeStill, shimmer.animation(forKey: "shimmer") == nil else { return }   // [settings] §3
        let move = CABasicAnimation(keyPath: "transform.translation.x")
        move.fromValue = -bounds.width * 0.66
        move.toValue = bounds.width * 0.66
        move.duration = 1.4
        move.repeatCount = .infinity
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shimmer.add(move, forKey: "shimmer")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, mode == .loading { startShimmer() }
    }

    /// [talk] Side by side; one above the other at accessibility text sizes.
    private func arrangeCapsules() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        capsules.axis = large ? .vertical : .horizontal
        capsules.alignment = large ? .fill : .center
        setNeedsLayout()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Only Retry, the intro's two capsules and Name Chat take touches; the rest lets the transcript (and keyboard
        // dismissal) work underneath.
        let hit = super.hitTest(point, with: event)
        guard let hit else { return nil }
        return [retryButton, talkButton, infoButton, nameButton].contains { hit.isDescendant(of: $0) } ? hit : nil
    }
}
