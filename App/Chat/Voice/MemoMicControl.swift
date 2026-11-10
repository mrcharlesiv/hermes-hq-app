// The mic in the composer's field (spec 1x-voice §3.1): a 44 pt control at the field's trailing end, shown only on an
// empty composer. Hold to record (let go to send), tap for hands-free, slide left to cancel, slide up to lock. It
// tracks its own touch (UIKit control tracking, window coordinates); a touch on it never focuses the field and never
// scrolls the chat.

import UIKit

final class MemoMicControl: UIControl {
    /// Touch-down (with nothing else recording): the take begins.
    var onDown: (() -> Void)?
    /// The finger moved: dx, dy from the touch-down point.
    var onMove: ((_ dx: CGFloat, _ dy: CGFloat) -> Void)?
    var onUp: (() -> Void)?
    var onCancel: (() -> Void)?
    /// VoiceOver's double-tap / Voice Control's "Tap": the locked recorder, never a hold.
    var onAccessibilityOpen: (() -> Void)?

    private let pressedCircle = UIView()
    private let glyph = UIImageView()
    /// [composer-expand] Where the composer put it (it keeps the place while a take it began runs).
    var placement: ComposerView.MicPlacement = .field
    /// [composer-expand] In the two-row bar it stands on a 36 pt glass disc like the +'s, the glyph in label.
    var onDisc = false {
        didSet {
            guard onDisc != oldValue else { return }
            glyph.image = UIImage(systemName: "mic", withConfiguration: onDisc ? ComposerGlassButton.discConfiguration
                                                                            : UIImage.SymbolConfiguration(pointSize: 20, weight: .regular))
            disc.isHidden = !onDisc || contentHidden
            applyPressed()
        }
    }
    private let disc: ComposerGlassDisc = {
        let view = ComposerGlassDisc()
        view.isHidden = true
        return view
    }()
    private var start: CGPoint = .zero
    /// The pressed look (from touch-down until the recorder confirms); never red before recording is confirmed.
    var pressed = false { didSet { if pressed != oldValue { applyPressed() } } }
    /// The recorder covers it: the glyph goes, the control keeps tracking its touch.
    var contentHidden = false {
        didSet {
            glyph.alpha = contentHidden ? 0 : 1
            disc.isHidden = !onDisc || contentHidden
            if contentHidden { pressedCircle.alpha = 0 } else { applyPressed() }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        pressedCircle.backgroundColor = ChatPalette.fill3
        pressedCircle.isUserInteractionEnabled = false
        pressedCircle.alpha = 0
        addSubview(disc)
        addSubview(pressedCircle)
        glyph.image = UIImage(systemName: "mic", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular))
        glyph.tintColor = ChatPalette.composerGlyph
        glyph.contentMode = .center
        glyph.isUserInteractionEnabled = false
        addSubview(glyph)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Record Voice Memo"
        accessibilityHint = "Hold to record, let go to send. Or tap to record hands-free."
        accessibilityIdentifier = "composer.mic"
        isExclusiveTouch = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        pressedCircle.frame = bounds.insetBy(dx: 4, dy: 4)
        pressedCircle.layer.cornerRadius = pressedCircle.bounds.width / 2
        disc.bounds = CGRect(origin: .zero, size: pressedCircle.frame.size)   // (the press scales it: no frame)
        disc.center = CGPoint(x: pressedCircle.frame.midX, y: pressedCircle.frame.midY)
        glyph.frame = bounds
    }

    private func applyPressed() {
        glyph.tintColor = pressed || onDisc ? ChatPalette.label : ChatPalette.composerGlyph
        let on = pressed && !contentHidden
        if onDisc {
            // [composer-glass] On its disc the glass sinks; the soft circle is the bare glyph's press.
            disc.press(on)
            pressedCircle.alpha = 0
            return
        }
        UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { // motion-ok: opacity only, no swell
            self.pressedCircle.alpha = on ? 1 : 0
        }
    }

    // MARK: Tracking (window coordinates; the field and the chat never see this touch)

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        start = touch.location(in: nil)
        onDown?()
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let p = touch.location(in: nil)
        onMove?(p.x - start.x, p.y - start.y)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if let touch {
            let p = touch.location(in: nil)
            onMove?(p.x - start.x, p.y - start.y)
        }
        onUp?()
        onTrackingEnded?()
    }

    override func cancelTracking(with event: UIEvent?) {
        onCancel?()
        onTrackingEnded?()
    }

    /// The touch is over (after `onUp` / `onCancel`): the composer decides whether the mic still shows.
    var onTrackingEnded: (() -> Void)?

    /// A drag anywhere keeps tracking: the finger slides far past the control's bounds.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.contains(point)
    }

    /// No other recognizer (the field's glass, a sheet's pull) may take this touch.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer.view === self
    }

    override func accessibilityActivate() -> Bool {
        onAccessibilityOpen?()
        return true
    }
}
