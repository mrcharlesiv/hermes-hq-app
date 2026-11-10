// The audio route (docs/spec/3x-talk.md §6.5): the route's name (the Read Aloud strip) or, `compact`, only its glyph (the
// conversation bar, shown there only for an external route), with the system's own route picker laid over it, so the
// finger touches the system control and the system presents its picker (DECISION T10). The name is refreshed on route
// changes only; the route is read off the main thread.

import AVFAudio
import AVKit
import UIKit

final class TalkRouteButton: UIView {
    private let glyph = UIImageView()
    private let label = UILabel()
    private let picker = AVRoutePickerView()
    private var observer: (any NSObjectProtocol)?
    private(set) var routeName = ""
    /// The route's kind as last read (the Read Aloud strip shows the button only off the built-in speaker).
    private(set) var kind: TalkRouteKind = .none
    /// The output port's type as last read (`AVAudioSession.Port` raw value): the compact glyph follows it.
    private(set) var portType = ""
    /// The output port's name as last read ("AirPods Pro"): the bar's speaker button names it.
    private(set) var portName: String?
    /// Glyph only (the conversation bar): AirPods, headphones, a car, AirPlay.
    let compact: Bool
    var onChange: (() -> Void)?

    /// Bluetooth, headphones, CarPlay or AirPlay: the bar shows the glyph only then.
    var isExternal: Bool { TalkDockState.routeIsExternal(kind) }

    convenience override init(frame: CGRect) { self.init(compact: false) }

    init(compact: Bool) {
        self.compact = compact
        super.init(frame: .zero)
        if compact {
            glyph.image = UIImage(systemName: "airplayaudio", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        } else {
            // Beside the name: sized by its text style, so it grows with the name (a fixed 11 pt was 8.5 on the Mac).
            glyph.image = UIImage(systemName: "airplayaudio")
            glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: HQFont.legibleStyle(.caption1))
                .applying(UIImage.SymbolConfiguration(weight: .semibold))
        }
        glyph.tintColor = tintColor
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.font = HQFont.preferred(.caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = tintColor
        label.lineBreakMode = .byTruncatingTail
        // The name keeps its width against the dock's hint (which wraps); the dock caps it.
        label.setContentCompressionResistancePriority(UILayoutPriority(760), for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: compact ? [glyph] : [glyph, label])
        row.axis = .horizontal
        row.spacing = 4
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        // The system control, over the label at the same size, its own glyph invisible.
        picker.tintColor = .clear
        picker.activeTintColor = .clear
        picker.prioritizesVideoDevices = false
        picker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(picker)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            picker.centerXAnchor.constraint(equalTo: centerXAnchor),
            picker.centerYAnchor.constraint(equalTo: centerYAnchor),
            picker.widthAnchor.constraint(greaterThanOrEqualTo: widthAnchor),
            row.widthAnchor.constraint(greaterThanOrEqualToConstant: compact ? 28 : 0),
            picker.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            picker.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "talk.dock.route"
        show(TalkDockState.routeName(.none, portName: nil, device: Self.device))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Listens for route changes only while it is on screen.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        guard window != nil else { return }
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    static var device: String { DeviceWord.name }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        glyph.tintColor = tintColor
        label.textColor = tintColor
    }

    /// The touch area is at least 44 × 44 pt around the label.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: min(0, (bounds.width - 44) / 2), dy: min(0, (bounds.height - 44) / 2)).contains(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard self.point(inside: point, with: event), !isHidden, alpha > 0.01 else { return nil }
        // Whatever inside the system picker takes touches gets this one.
        let inside = CGPoint(x: picker.bounds.midX, y: picker.bounds.midY)
        return picker.hitTest(inside, with: event) ?? picker
    }

    override func accessibilityActivate() -> Bool { openPicker() }

    /// Presents the system's route picker (the bar's long-press menu, VoiceOver).
    @discardableResult func openPicker() -> Bool {
        for case let button as UIControl in picker.subviews {
            button.sendActions(for: .touchUpInside)
            return true
        }
        return false
    }

    #if DEBUG
    /// Tests and screenshots: a route the simulator cannot have (AirPods), as (kind, port type, name).
    static var debugRoute: (kind: TalkRouteKind, type: String, name: String)?
    #endif

    func refresh() {
        #if DEBUG
        if let route = Self.debugRoute {
            apply(kind: route.kind, name: route.name, type: route.type)
            return
        }
        #endif
        Task { [weak self] in
            let read: (kind: TalkRouteKind, name: String?, type: String) = await AudioWork.perform {
                guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return (.none, nil, "") }
                return (TalkRouteButton.kind(port.portType), port.portName, port.portType.rawValue)
            }
            self?.apply(kind: read.kind, name: read.name, type: read.type)
        }
    }

    private func apply(kind: TalkRouteKind, name: String?, type: String) {
        self.kind = kind
        portType = type
        portName = name
        if compact {
            glyph.image = UIImage(systemName: TalkDockState.routeSymbol(portType: type, name: name),
                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        }
        show(TalkDockState.routeName(kind, portName: name, device: Self.device))
        onChange?()
    }

    nonisolated static func kind(_ port: AVAudioSession.Port) -> TalkRouteKind {
        switch port {
        case .builtInReceiver: .receiver
        case .builtInSpeaker: .speaker
        case .headphones: .headphones
        default: .other
        }
    }

    private func show(_ name: String) {
        routeName = name
        label.text = name
        accessibilityLabel = "Audio route: \(name). Choose another"
        accessibilityValue = name
    }
}
