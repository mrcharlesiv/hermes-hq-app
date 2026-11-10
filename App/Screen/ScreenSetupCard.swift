import UIKit

/// The Mac setup card (docs/spec/3x-screen.md §5.13): one tap asks the bot, in its own chat, to install the helper and
/// plugin and check both permissions. The words are the web app's. A grouped inset card; the buttons are system glass
/// in the Desktop Look, solid capsules in the iOS look.
final class ScreenSetupCard: UIView {
    /// Starts the request. Returns a failure only when it happened before the Screen closed (later ones show as an
    /// alert on the chat).
    var onSetup: (() async -> ScreenSetupError?)?
    /// "Check setup": the readiness line.
    var onCheck: (() async throws -> String)?

    private let controlOnly: Bool
    private let stack = UIStackView()
    private let heading = UILabel()
    private let how = UILabel()
    private let shares = UILabel()
    private let update = UILabel()
    private let message = UILabel()
    private let error = UILabel()
    private let windowsNote = UILabel()
    // [glass-design] No glass inside the solid card: the accent capsule and a tinted capsule in the iOS look; the
    // Desktop Look and the Mac keep their buttons.
    private let primary = UIButton(configuration: GlassSheetKit.designed ? .hqSheetProminent() : .hqProminentGlass())
    private let second = UIButton(configuration: GlassSheetKit.designed ? .hqSheetAction(onCard: true) : .hqGlass())
    private var busy = false
    private var checking = false

    /// Setup was already requested for this bot in this run.
    var requested = false { didSet { if requested != oldValue { apply() } } }
    /// The gateway predates the Screen: the card adds the update line.
    var needsUpdate = false { didSet { if needsUpdate != oldValue { apply() } } }
    /// A Windows gateway: one sentence, no buttons.
    var windows = false { didSet { if windows != oldValue { apply() } } }

    init(controlOnly: Bool) {
        self.controlOnly = controlOnly
        super.init(frame: .zero)
        backgroundColor = HQPalette.card
        layer.cornerRadius = HQShape.radius(22, .card)
        layer.cornerCurve = .continuous
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        style(heading, .headline, HQPalette.label, "screen.setup.heading")
        heading.accessibilityTraits = .header
        style(how, .subheadline, HQPalette.label2, "screen.setup.how")
        style(shares, .subheadline, HQPalette.label2, "screen.setup.shares")
        style(update, .subheadline, HQPalette.label2, "screen.setup.update")
        style(message, .subheadline, HQPalette.label, "screen.setup.message")
        style(error, .subheadline, HQPalette.red, "screen.setup.error")   // [glass-design] the theme's readable red
        style(windowsNote, .subheadline, HQPalette.label2, "screen.setup.windows")
        how.text = ScreenSetupCopy.how
        shares.text = ScreenSetupCopy.shares
        update.text = ScreenSetupCopy.update
        windowsNote.text = ScreenSetupCopy.windows
        for button in [primary, second] {
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.configuration?.titleLineBreakMode = .byWordWrapping
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        }
        primary.accessibilityIdentifier = "screen.setup.primary"
        second.accessibilityIdentifier = "screen.setup.check"
        primary.addAction(UIAction { [weak self] _ in self?.setup() }, for: .primaryActionTriggered)
        second.addAction(UIAction { [weak self] _ in self?.check() }, for: .primaryActionTriggered)
        let buttons = UIStackView(arrangedSubviews: [primary, second])
        buttons.axis = .vertical
        buttons.spacing = 10
        buttons.isLayoutMarginsRelativeArrangement = true
        buttons.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
        for view in [padded(windowsNote), padded(heading), padded(how), padded(shares), buttons, padded(update), padded(message), padded(error)] {
            stack.addArrangedSubview(view)
        }
        accessibilityIdentifier = controlOnly ? "screen.setup.card.control" : "screen.setup.card"
        apply()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func style(_ label: UILabel, _ text: UIFont.TextStyle, _ color: UIColor, _ id: String) {
        label.font = HQFont.preferred(text)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textColor = color
        label.accessibilityIdentifier = id
    }

    /// Wrapping lines get 12 pt above and below.
    private func padded(_ label: UILabel) -> UIView {
        let box = UIStackView(arrangedSubviews: [label])
        box.isLayoutMarginsRelativeArrangement = true
        box.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0)
        return box
    }

    private func show(_ label: UILabel, _ on: Bool) { label.superview?.isHidden = !on }

    private func apply() {
        heading.text = ScreenSetupCopy.heading(controlOnly: controlOnly)
        show(windowsNote, windows)
        show(heading, !windows)
        show(how, !windows)
        show(shares, !windows)
        primary.superview?.isHidden = windows
        show(update, !windows && needsUpdate)
        show(message, !windows && !(message.text ?? "").isEmpty)
        show(error, !windows && !(error.text ?? "").isEmpty)
        primary.configuration?.title = ScreenSetupCopy.primary(requested: requested, controlOnly: controlOnly, working: busy)
        primary.configuration?.showsActivityIndicator = busy
        second.configuration?.title = ScreenSetupCopy.check(working: checking)
        second.configuration?.showsActivityIndicator = checking
        primary.isEnabled = !busy && !checking
        second.isEnabled = !busy && !checking
        accessibilityElementsHidden = false
    }

    /// Shows the "requested" line (the Screen was reopened after a request).
    func showRequested() {
        requested = true
        message.text = ScreenSetupCopy.requested
        apply()
    }

    private func setup() {
        guard !busy, let onSetup else { return }
        busy = true
        error.text = ""
        apply()
        Task { [weak self] in
            let failure = await onSetup()
            guard let self else { return }
            busy = false
            if let failure {
                error.text = failure.message
                HQAnnounce.say(failure.message)
            } else {
                requested = true
                message.text = ScreenSetupCopy.requested
            }
            apply()
        }
    }

    private func check() {
        guard !checking, let onCheck else { return }
        checking = true
        error.text = ""
        apply()
        Task { [weak self] in
            var line: String?, failure: String?
            do { line = try await onCheck() } catch { failure = ScreenWire.message(error) }
            guard let self else { return }
            checking = false
            if let line {
                message.text = line
                HQAnnounce.say(line)
            }
            if let failure { self.error.text = failure }
            apply()
        }
    }
}

/// The control-only card as a sheet over a live Mac Screen, so it never covers the picture (§5.9).
final class ScreenSetupSheet: UIViewController {
    let card = ScreenSetupCard(controlOnly: true)
    /// The sheet went away (closed, swiped down, or the Screen under it closed).
    var onGone: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true || presentingViewController == nil { onGone?() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // [glass-design] On Liquid Glass at half height: the card is solid (iOS draws the grouped card see-through
        // on glass), and nothing else stands on the glass.
        view.backgroundColor = HQPalette.sheetPage
        card.backgroundColor = HQPalette.sheetCard
        card.hqGlassEdge()   // [glass-design] its thin edge on the glass
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        view.addSubview(scroll)
        card.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(card)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            card.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            card.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
        ])
        // [glass-design] The grouped cards' edges in the iOS look (the view's margins), 16 pt in the Desktop Look as before.
        if GlassSheetKit.designed {
            card.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor).isActive = true
            card.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor).isActive = true
        } else {
            card.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16).isActive = true
            card.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16).isActive = true
        }
    }
}
