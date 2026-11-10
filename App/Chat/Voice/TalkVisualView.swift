// The dock's state visual (docs/spec/3x-talk.md §6.1): five bars that follow the level while listening or speaking,
// three dots that pulse in turn while waiting, the system spinner while transcribing, and a muted glyph. Drawn with
// layers; a level update moves five bounds and lays nothing out.

import UIKit

final class TalkVisualView: UIView {
    enum Mode: Equatable { case listening, speaking, dots, spinner, muted }

    /// The visual's sizes: the old dock's (44 × 32), the conversation bar's field (28 × 24) and End's indicator (the
    /// desktop's `ConversationIndicator`: five 2 pt bars, 12 pt tall).
    struct Style: Equatable {
        var size: CGSize
        var barWidth: CGFloat
        var barGap: CGFloat
        var full: CGFloat
        var dot: CGFloat
        var dotGap: CGFloat
        var glyph: CGFloat
        static let dock = Style(size: CGSize(width: 44, height: 32), barWidth: 4, barGap: 4, full: 28, dot: 7, dotGap: 6, glyph: 22)
        static let field = Style(size: CGSize(width: 28, height: 24), barWidth: 3, barGap: 2.5, full: 20, dot: 5, dotGap: 4, glyph: 16)
        static let indicator = Style(size: CGSize(width: 16, height: 12), barWidth: 2, barGap: 1.5, full: 12, dot: 3, dotGap: 2, glyph: 10)
    }

    static let size = Style.dock.size
    private static let weights: [Double] = [0.55, 0.85, 1, 0.85, 0.55]
    let style: Style

    private let bars: [CALayer] = (0..<5).map { _ in CALayer() }
    private let dots: [CALayer] = (0..<3).map { _ in CALayer() }
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let glyph = UIImageView()
    private(set) var mode: Mode = .dots
    private var level = 0.0

    init(style: Style = .dock) {
        self.style = style
        super.init(frame: CGRect(origin: .zero, size: style.size))
        isAccessibilityElement = false
        for bar in bars {
            bar.cornerRadius = style.barWidth / 2
            bar.cornerCurve = .continuous
            layer.addSublayer(bar)
        }
        for dot in dots {
            dot.cornerRadius = style.dot / 2
            layer.addSublayer(dot)
        }
        spinner.hidesWhenStopped = true
        addSubview(spinner)
        glyph.image = UIImage(systemName: "mic.slash", withConfiguration: UIImage.SymbolConfiguration(pointSize: style.glyph, weight: .medium))
        glyph.tintColor = ChatPalette.label2
        glyph.contentMode = .center
        addSubview(glyph)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: TalkVisualView, _) in view.applyColors() }
        apply(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: CGSize { style.size }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyColors()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { apply(animated: false) }     // layer animations do not survive leaving the window
    }

    func set(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        apply(animated: false)
    }

    /// 0…1. Bars follow it with a 90 ms ease (none under Reduce Motion: they are information, so they still move).
    func setLevel(_ level: Double) {
        self.level = max(0, min(1, level.isFinite ? level : 0))
        guard mode == .listening || mode == .speaking else { return }
        layoutBars(animated: !HQMotion.reduced)
    }

    private func height(_ index: Int) -> CGFloat {
        let weight = Self.weights[index]
        let part = mode == .speaking ? 0.35 + 0.65 * weight * level : 0.25 + min(0.75, level * 1.4 * weight)
        return CGFloat(part) * style.full
    }

    private func layoutBars(animated: Bool) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.09)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        let total = style.barWidth * 5 + style.barGap * 4
        var x = (bounds.width - total) / 2
        for (index, bar) in bars.enumerated() {
            let h = height(index)
            bar.bounds = CGRect(x: 0, y: 0, width: style.barWidth, height: h)
            bar.position = CGPoint(x: x + style.barWidth / 2, y: bounds.midY)
            x += style.barWidth + style.barGap
        }
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        glyph.frame = bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let gap = style.dotGap, side = style.dot
        var x = (bounds.width - (side * 3 + gap * 2)) / 2
        for dot in dots {
            dot.frame = CGRect(x: x, y: bounds.midY - side / 2, width: side, height: side)
            x += side + gap
        }
        CATransaction.commit()
        layoutBars(animated: false)
    }

    private func applyColors() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let tint = tintColor.resolvedColor(with: traitCollection).cgColor
        for bar in bars { bar.backgroundColor = tint }
        let quiet = ChatPalette.label2.resolvedColor(with: traitCollection).cgColor
        for dot in dots { dot.backgroundColor = quiet }
        CATransaction.commit()
    }

    private func apply(animated: Bool) {
        let showBars = mode == .listening || mode == .speaking
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for bar in bars { bar.isHidden = !showBars }
        for dot in dots { dot.isHidden = mode != .dots }
        CATransaction.commit()
        glyph.isHidden = mode != .muted
        if mode == .spinner { spinner.startAnimating() } else { spinner.stopAnimating() }
        applyColors()
        for (index, dot) in dots.enumerated() {
            dot.removeAnimation(forKey: "pulse")
            dot.opacity = 0.9
            // Still under Reduce Motion (§6.1).
            guard mode == .dots, !HQMotion.reduced else { continue }
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0.3, 1, 0.3, 0.3]
            pulse.keyTimes = [0, 0.25, 0.5, 1]
            pulse.duration = 1.2
            pulse.beginTime = CACurrentMediaTime() + Double(index) * 0.2
            pulse.repeatCount = .infinity
            dot.add(pulse, forKey: "pulse")
        }
        setNeedsLayout()
    }
}
