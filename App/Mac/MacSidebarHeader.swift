#if targetEnvironment(macCatalyst)
import UIKit

/// Open sidebar top header row (height = `MacGlassShell.topBarHeight`, aligned horizontally with macOS traffic lights):
/// trailing Search (`⌘K`) and Compose (`⌘N`) compact icon buttons + draggable empty chrome strip.
@MainActor
final class MacSidebarHeader: UIView {
    static let totalHeight: CGFloat = MacGlassShell.topBarHeight

    private let searchButton = HeaderIconButton(symbol: "magnifyingglass", label: "Search", tip: "Search or jump to… (⌘K)", id: "mac-sidebar.search")
    private let composeButton = HeaderIconButton(symbol: "square.and.pencil", label: "New Chat", tip: "New Chat (⌘N)", id: "mac-sidebar.compose")

    private var attachToken: NSObjectProtocol?
    private var centerYOffset: CGFloat = 0
    private var didAlignTrafficLights = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "mac-sidebar.tools"
        backgroundColor = .clear
        isOpaque = false

        searchButton.addAction(UIAction { _ in
            UIApplication.shared.sendAction(KeyCommands.openQuickly, to: UIApplication.shared.delegate, from: nil, for: nil)
        }, for: .touchUpInside)
        composeButton.addAction(UIAction { _ in
            UIApplication.shared.sendAction(KeyCommands.newChat, to: UIApplication.shared.delegate, from: nil, for: nil)
        }, for: .touchUpInside)

        addSubview(searchButton)
        addSubview(composeButton)

        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        drag.delegate = self
        addGestureRecognizer(drag)

        attachToken = NotificationCenter.default.addObserver(forName: MacGlassShell.didAttachWindow, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.didAlignTrafficLights = false
                self?.alignToTrafficLights()
            }
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: MacSidebarHeader, _) in
            view.recolor()
        }
        recolor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        if let attachToken { NotificationCenter.default.removeObserver(attachToken) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        alignToTrafficLights()
    }

    private func alignToTrafficLights() {
        guard let window, bounds.height > 0 else { return }
        guard MacGlassShell.nsWindow(for: window) != nil else { return }
        didAlignTrafficLights = true
        let metrics = MacGlassShell.trafficLightsMetrics(in: window)
        let localMid = convert(CGPoint(x: 0, y: metrics.midY), from: window).y
        let target = localMid - MacGlassShell.topBarHeight / 2
        if abs(target) < 12, abs(target - centerYOffset) > 0.25 {
            centerYOffset = target
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !didAlignTrafficLights, window != nil, bounds.height > 0 { alignToTrafficLights() }
        let topH = MacGlassShell.topBarHeight
        let midY = max(13, min(topH - 13, topH / 2 + centerYOffset))
        let btnSize: CGFloat = 28
        let inset = MacSidebar.inset

        let composeX = bounds.width - inset - btnSize
        let searchX = composeX - 4 - btnSize
        composeButton.frame = CGRect(x: composeX, y: (midY - btnSize / 2).rounded(), width: btnSize, height: btnSize)
        searchButton.frame = CGRect(x: searchX, y: (midY - btnSize / 2).rounded(), width: btnSize, height: btnSize)
    }

    func recolor() {
        searchButton.recolor()
        composeButton.recolor()
    }

    @objc private func handleDrag(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began {
            MacGlassShell.beginWindowDrag(for: window)
        }
    }
}

extension MacSidebarHeader: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var v = touch.view
        while let current = v, current !== self {
            if current is UIControl { return false }
            v = current.superview
        }
        return true
    }
}

// MARK: - Top Row Icon Button

@MainActor
private final class HeaderIconButton: UIControl {
    private let bg = UIView()
    private let icon = UIImageView()
    private let symbolName: String
    private var isPointerOver = false

    init(symbol: String, label: String, tip: String, id: String) {
        self.symbolName = symbol
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = id
        accessibilityLabel = label
        toolTip = tip
        MacTitleBarClick.markInteractive(self)
        MacHover.drawsOwnHover(self)

        bg.isUserInteractionEnabled = false
        bg.layer.cornerRadius = 8
        bg.layer.cornerCurve = .continuous
        addSubview(bg)

        icon.isUserInteractionEnabled = false
        icon.contentMode = .center
        icon.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13.5, weight: .medium))
        addSubview(icon)

        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
        recolor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        bg.frame = bounds
        icon.frame = bounds
    }

    override var isHighlighted: Bool { didSet { recolor() } }

    @objc private func hover(_ g: UIHoverGestureRecognizer) {
        isPointerOver = g.state == .began || g.state == .changed
        recolor()
    }

    func recolor() {
        let dark = traitCollection.userInterfaceStyle == .dark
        icon.tintColor = isPointerOver ? HQPalette.label : HQPalette.label.withAlphaComponent(dark ? 0.68 : 0.60)
        if isHighlighted {
            bg.backgroundColor = dark ? UIColor(white: 1, alpha: 0.14) : UIColor(white: 0, alpha: 0.09)
        } else if isPointerOver {
            bg.backgroundColor = dark ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 0, alpha: 0.055)
        } else {
            bg.backgroundColor = .clear
        }
    }
}
#endif
