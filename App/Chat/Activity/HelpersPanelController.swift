import UIKit

/// [mac-layout] The inspector's Helpers tab: the subagents card's list and helper page, scrolling on their own, with a
/// line when the chat has none. ChatActivityController feeds `body` as it feeds the card above the composer.
final class HelpersPanelController: UIViewController {
    let body = SubagentsBody(panel: true)
    /// The tab came on screen (the open helper's tail is read while it shows).
    var onShown: (() -> Void)?
    private let scroll = UIScrollView()
    private let empty = InspectorEmptyView(symbol: "person.2", title: "No Helpers",
                                           hint: "Helpers a bot starts during a reply are listed here, with their steps.")
    private var timer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        body.accessibilityIdentifier = "mac.inspector.helpers"
        scroll.addSubview(body)
        empty.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        view.addSubview(empty)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            body.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            body.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
            // Mac polish #61: where the inspector's other empty lines stand (`MacInspector`, the Steps tab).
            empty.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            empty.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            empty.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            empty.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onShown?()
        // Running helpers' times count up while the tab shows.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.body.tick(now: Date().timeIntervalSince1970) }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        timer?.invalidate()
        timer = nil
        onShown?()
    }

    /// `fill` updates the body; nil: the chat has no helpers.
    func show(_ fill: (() -> Void)?) {
        loadViewIfNeeded()
        empty.isHidden = fill != nil
        scroll.isHidden = fill == nil
        fill?()
    }
}

/// [mac-ui-issues] Owner 2026-11-09 (the inspector: "awkwardly sized and laid out. Like we just tossed shit there"): an
/// empty tab was one grey sentence in the middle of the panel. Every empty tab now reads the same way: a glyph, what is
/// missing, and a line on what will show there (where polish #61 put the sentence: the panel's middle, 40 pt up).
final class InspectorEmptyView: UIView {
    private let glyph = UIImageView()
    private let titleLabel = UILabel()
    private let hintLabel = UILabel()

    init(symbol: String, title: String, hint: String) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        glyph.contentMode = .scaleAspectFit
        glyph.tintColor = HQPalette.label3
        titleLabel.font = HQFont.preferred(.headline)
        titleLabel.textColor = HQPalette.label2
        hintLabel.font = HQFont.preferred(.footnote)
        hintLabel.textColor = HQPalette.label2
        for label in [titleLabel, hintLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.textAlignment = .center
            label.numberOfLines = 0
        }
        let stack = UIStackView(arrangedSubviews: [glyph, titleLabel, hintLabel])
        stack.axis = .vertical
        // The labels take the stack's width (their text is centred): centred at their own width, a label squeezed once
        // (the panel a few points wide for a moment as the window was dragged narrow) kept that as its wrapping width
        // and stayed one letter wide (hunt 2026-11-09).
        stack.alignment = .fill
        stack.spacing = 4
        stack.setCustomSpacing(10, after: glyph)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // A width of its own (280, less only in a narrower panel): centred with nothing but "no wider than", its
        // wrapping labels could settle one letter wide after the window was dragged narrow (hunt 2026-11-09).
        let wanted = stack.widthAnchor.constraint(equalToConstant: 280)
        wanted.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
            wanted,
        ])
        isAccessibilityElement = true
        set(symbol: symbol, title: title, hint: hint)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func set(symbol: String, title: String, hint: String) {
        glyph.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .light))
        titleLabel.text = title
        hintLabel.text = hint
        accessibilityLabel = "\(title). \(hint)"
    }
}
