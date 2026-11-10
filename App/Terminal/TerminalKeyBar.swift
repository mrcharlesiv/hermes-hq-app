// [terminal] The keys a phone keyboard lacks, over it: Esc, Ctrl (held for the next key typed) and Tab at the left,
// the arrows at the right, nothing between.
// A tester (Discord, 2026-11-04): → sat off the edge of an iPhone in a row that scrolled only from its gaps.
// Owner 2026-11-04 on build 784's row ("This bar with the buttons is an awful UI UX") and on a row of keyboard key
// caps ("I don't want all of that in one row. Find another way"), then picked layout A of three mockups: only the
// keys a terminal needs at hand, as key caps of the iOS keyboard under them. What left the row has a home already:
// | ~ / - are on the keyboard's 123 page, Paste is on a hold of the screen (iOS's own menu, which doesn't ask "Allow
// Paste?") and in ⋯, and the keyboard hides with a drag of the screen down into it (or the key bar's VoiceOver
// action).

import SwiftTerm
import UIKit

final class TerminalKeyBar: UIView, UIInputViewAudioFeedback {
    private weak var terminal: TerminalView?
    private var ctrl: UIButton?
    private var resetObserver: NSObjectProtocol?

    static let height: CGFloat = 52
    /// A key's face: the dark keyboard's letter keys (sampled from an iPhone, iOS 27), on the terminal's dark panel.
    static let capColor = UIColor(red: 0.27, green: 0.27, blue: 0.28, alpha: 1)  // solid-ok: a keyboard key, as iOS draws its own
    static let capPressed = UIColor(red: 0.42, green: 0.42, blue: 0.44, alpha: 1)
    static var capRadius: CGFloat { Theme.isDesktop ? DesktopRows.radius : 8.5 }
    /// A key's face is 40 pt of its 44 pt row, as the keyboard's keys sit with a gap above and below.
    static let capHeight: CGFloat = 40
    static let gap: CGFloat = 6
    static let keyWidth: CGFloat = 48

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Self.height))
        autoresizingMask = .flexibleHeight
        backgroundColor = .clear
        // The keyboard under it is dark (the terminal's), in every look.
        overrideUserInterfaceStyle = .dark
        accessibilityIdentifier = "terminal.keys"

        let keys = UIStackView()
        keys.translatesAutoresizingMaskIntoConstraints = false
        keys.axis = .horizontal
        keys.spacing = Self.gap
        keys.alignment = .center
        addSubview(keys)
        keys.addArrangedSubview(key("esc", spoken: "Escape", id: "esc") { $0.send([0x1b]) })
        let ctrl = key("ctrl", spoken: "Control", id: "ctrl") { [weak self] _ in self?.toggleControl() }
        self.ctrl = ctrl
        keys.addArrangedSubview(ctrl)
        keys.addArrangedSubview(key("tab", spoken: "Tab", id: "tab") { $0.send([0x09]) })

        let pad = TerminalArrowPad { [weak self] direction in
            guard let terminal = self?.terminal else { return }
            switch direction {
            case .left: terminal.sendKeyLeft()
            case .up: terminal.sendKeyUp()
            case .down: terminal.sendKeyDown()
            case .right: terminal.sendKeyRight()
            }
        }
        addSubview(pad)
        NSLayoutConstraint.activate([
            keys.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: Self.gap),
            keys.centerYAnchor.constraint(equalTo: centerYAnchor),
            pad.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -Self.gap),
            pad.centerYAnchor.constraint(equalTo: centerYAnchor),
            pad.leadingAnchor.constraint(greaterThanOrEqualTo: keys.trailingAnchor, constant: Self.gap),
        ])

        // The drag that hides the keyboard can't be seen by VoiceOver: the bar offers it.
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Hide Keyboard") { [weak self] _ in
            self?.terminal?.resignFirstResponder() ?? false
        }]

        resetObserver = NotificationCenter.default.addObserver(forName: .terminalViewControlModifierReset, object: terminal,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showControl(false) }
        }
    }

    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        if let resetObserver { NotificationCenter.default.removeObserver(resetObserver) }
    }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.height) }

    var enableInputClicksWhenVisible: Bool { true }

    // MARK: Keys

    /// A key cap: the keyboard's grey key in the iOS look (white with dark ink while Ctrl is held, as Shift shows),
    /// the outlined box of the Desktop Look's buttons there (the accent while held).
    static func capConfiguration(held: Bool = false) -> UIButton.Configuration {
        var config: UIButton.Configuration
        if Theme.isDesktop {
            config = held ? .hqProminentGlass() : .hqGlass()
            config.baseForegroundColor = held ? HQPalette.onTint : .white
        } else {
            config = .filled()
            config.baseBackgroundColor = held ? .white : capColor
            config.baseForegroundColor = held ? .black : .white
        }
        config.cornerStyle = .fixed
        config.background.cornerRadius = capRadius
        config.background.backgroundInsets = NSDirectionalEdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0)
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 2, bottom: 6, trailing: 2)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            // [ui-sizing] monoFace: `mono` multiplies by UI Scale, and at 125 % "ctrl" no longer fit its 48 pt key ("c…").
            attributes.font = HQFont.monoFace(ofSize: 15, weight: .medium)  // key caps keep their size, as iOS's own keyboard does
            return attributes
        }
        return config
    }

    private func style(_ button: UIButton, held: Bool = false) {
        button.configuration = Self.capConfiguration(held: held)
        // Pressed, the face lightens, as a keyboard key's does (the look's own press is a dim, which reads as off).
        button.configurationUpdateHandler = Theme.isDesktop || held ? nil : { button in
            button.configuration?.baseBackgroundColor = button.isHighlighted ? Self.capPressed : Self.capColor
        }
    }

    private func key(_ title: String, spoken: String, id: String, _ press: @escaping (TerminalView) -> Void) -> UIButton {
        let button = UIButton(type: .custom)
        button.accessibilityLabel = spoken
        button.accessibilityIdentifier = "terminal.key." + id
        button.showsLargeContentViewer = true
        button.largeContentTitle = spoken
        button.addInteraction(UILargeContentViewerInteraction())
        NSLayoutConstraint.activate([button.heightAnchor.constraint(equalToConstant: 44),
                                     button.widthAnchor.constraint(equalToConstant: Self.keyWidth)])
        style(button)
        button.configuration?.title = title
        button.addAction(UIAction { [weak self] _ in
            guard let self, let terminal else { return }
            UIDevice.current.playInputClick()
            press(terminal)
        }, for: .primaryActionTriggered)
        return button
    }

    // MARK: Ctrl

    private func toggleControl() {
        guard let terminal else { return }
        terminal.controlModifier.toggle()
        showControl(terminal.controlModifier)
    }

    private func showControl(_ held: Bool) {
        guard let ctrl else { return }
        style(ctrl, held: held)
        ctrl.configuration?.title = "ctrl"
        ctrl.accessibilityValue = held ? "On, for the next key" : nil
    }
}

/// The four arrows as a laptop's: ← and → whole keys, ↑ over ↓ in half keys between them. One control, so a thumb
/// can slide from one arrow to the next without lifting; the pressed arrow sends at once, then every 80 ms after the
/// first 400 ms held, as a keyboard's keys repeat. Each arrow's touch area is the key drawn for it, run out to the
/// middle of the gaps.
final class TerminalArrowPad: UIControl {
    enum Direction: CaseIterable {
        case left, up, down, right

        var symbol: String {
            switch self {
            case .left: "arrowtriangle.left.fill"
            case .up: "arrowtriangle.up.fill"
            case .down: "arrowtriangle.down.fill"
            case .right: "arrowtriangle.right.fill"
            }
        }

        var spoken: String {
            switch self {
            case .left: "Left"
            case .up: "Up"
            case .down: "Down"
            case .right: "Right"
            }
        }
    }

    /// One column: a key's width.
    static let column: CGFloat = 38
    /// Between the columns, and between ↑ and ↓.
    static let gap: CGFloat = 4
    static let width: CGFloat = column * 3 + gap * 2
    private let press: (Direction) -> Void
    private var caps: [Direction: UIView] = [:]
    private var arrows: [Direction: UIImageView] = [:]
    private var held: Direction?
    private var repeating: Task<Void, Never>?

    init(press: @escaping (Direction) -> Void) {
        self.press = press
        super.init(frame: CGRect(x: 0, y: 0, width: Self.width, height: 44))
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "terminal.key.arrows"
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: Self.width), heightAnchor.constraint(equalToConstant: 44)])
        let desktop = Theme.isDesktop
        for direction in Direction.allCases {
            let cap = UIView()
            cap.isUserInteractionEnabled = false
            cap.layer.cornerRadius = direction == .up || direction == .down ? min(TerminalKeyBar.capRadius, 6) : TerminalKeyBar.capRadius
            cap.layer.cornerCurve = .continuous
            if desktop {
                cap.layer.borderColor = ChatPalette.strokeSecondary.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).cgColor
                cap.layer.borderWidth = 1
            } else {
                cap.backgroundColor = TerminalKeyBar.capColor
            }
            addSubview(cap)
            caps[direction] = cap
            let half = direction == .up || direction == .down
            let image = UIImageView(image: UIImage(systemName: direction.symbol,
                                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: half ? 9 : 12, weight: .semibold)))
            image.tintColor = .white
            image.contentMode = .center
            image.isUserInteractionEnabled = false
            cap.addSubview(image)
            arrows[direction] = image
        }
        isAccessibilityElement = false
        accessibilityElements = Direction.allCases.map { ArrowElement(pad: self, direction: $0) }
    }

    @MainActor required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit { repeating?.cancel() }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (direction, cap) in caps {
            cap.frame = Self.face(direction, in: bounds)
            arrows[direction]?.frame = cap.bounds
        }
    }

    /// Where a key is drawn: three columns, each a key 40 pt tall, the middle one split in two.
    static func face(_ direction: Direction, in bounds: CGRect) -> CGRect {
        let height = TerminalKeyBar.capHeight
        let top = bounds.midY - height / 2
        let half = (height - gap) / 2
        switch direction {
        case .left: return CGRect(x: 0, y: top, width: column, height: height)
        case .up: return CGRect(x: column + gap, y: top, width: column, height: half)
        case .down: return CGRect(x: column + gap, y: top + half + gap, width: column, height: half)
        case .right: return CGRect(x: (column + gap) * 2, y: top, width: column, height: height)
        }
    }

    /// Which arrow a point is on: the column it falls in (split at the gaps' middles), and in the middle column the
    /// half, top or bottom.
    static func direction(at point: CGPoint, in bounds: CGRect) -> Direction {
        let split = bounds.width / 3
        if point.x < split { return .left }
        if point.x >= split * 2 { return .right }
        return point.y < bounds.midY ? .up : .down
    }

    /// Where VoiceOver and UI tests find each arrow: its touch area.
    func zone(_ direction: Direction) -> CGRect {
        let third = bounds.width / 3
        switch direction {
        case .left: return CGRect(x: 0, y: 0, width: third, height: bounds.height)
        case .right: return CGRect(x: third * 2, y: 0, width: third, height: bounds.height)
        case .up: return CGRect(x: third, y: 0, width: third, height: bounds.height / 2)
        case .down: return CGRect(x: third, y: bounds.height / 2, width: third, height: bounds.height / 2)
        }
    }

    // MARK: Touches

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        hold(Self.direction(at: touch.location(in: self), in: bounds))
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let direction = Self.direction(at: touch.location(in: self), in: bounds)
        if direction != held { hold(direction) }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) { release() }

    override func cancelTracking(with event: UIEvent?) { release() }

    /// One press, as VoiceOver's double-tap does.
    func tap(_ direction: Direction) {
        UIDevice.current.playInputClick()
        press(direction)
    }

    private func hold(_ direction: Direction) {
        held = direction
        show(direction)
        tap(direction)
        repeating?.cancel()
        repeating = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled {
                guard let self, let held = self.held else { return }
                self.press(held)
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func release() {
        held = nil
        repeating?.cancel()
        repeating = nil
        show(nil)
    }

    /// The pressed key lightens, as a keyboard key does.
    private func show(_ pressed: Direction?) {
        let desktop = Theme.isDesktop
        for (direction, cap) in caps {
            let on = direction == pressed
            if desktop {
                cap.backgroundColor = on ? UIColor(white: 1, alpha: 0.12) : nil
            } else {
                cap.backgroundColor = on ? TerminalKeyBar.capPressed : TerminalKeyBar.capColor
            }
        }
    }
}

/// One arrow of the pad, for VoiceOver and UI tests (`terminal.key.left` …).
private final class ArrowElement: UIAccessibilityElement {
    private weak var pad: TerminalArrowPad?
    private let direction: TerminalArrowPad.Direction

    init(pad: TerminalArrowPad, direction: TerminalArrowPad.Direction) {
        self.pad = pad
        self.direction = direction
        super.init(accessibilityContainer: pad)
        accessibilityLabel = direction.spoken
        accessibilityIdentifier = "terminal.key." + direction.spoken.lowercased()
        accessibilityTraits = .button
    }

    override var accessibilityFrameInContainerSpace: CGRect {
        get { pad?.zone(direction) ?? .zero }
        set {}
    }

    override func accessibilityActivate() -> Bool {
        pad?.tap(direction)
        return true
    }
}
