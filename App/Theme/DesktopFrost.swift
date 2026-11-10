// desktop-frost: the Desktop Look's see-through bands (owner, build 321: "the top and bottom bars are no longer
// transparent like they were"). Builds 316 and 319 took the iOS 26 soft scroll edges away in the look and left solid
// page-colour bands behind the chat's bar and composer. The desktop's composer dock is a translucent fill over a
// backdrop blur (composer-dock.ts: `backdrop-blur 0.75rem`, `saturate 1.12`): so here, a plain blur (never Liquid
// Glass, `UIGlassEffect`) under the page colour at part alpha. Content behind it shows through softened; the band fades
// out over its inner edge, as the soft edge did, so no hard line cuts the transcript.

import UIKit

enum DesktopFrost {
    /// How much of the page colour lies over the blur: the content reads through, never against the bar's own text.
    static let tintAlpha: CGFloat = 0.3
    /// The blur under the tint (the system's plain blur, light and dark by itself; not glass).
    static func blur() -> UIBlurEffect { UIBlurEffect(style: .regular) }

    /// `base` at the band's alpha, following the trait (light, dark, the skin).
    static func tint(_ base: UIColor, alpha: CGFloat = tintAlpha) -> UIColor {
        UIColor { traits in base.resolvedColor(with: traits).withAlphaComponent(alpha) }
    }

    /// A bar in the look (every state, sheets included): the same frost, no line.
    static func barAppearance(_ appearance: UINavigationBarAppearance, color: UIColor) {
        // Opaque's configuration, then made see-through: on iOS 26 the default configuration leaves the background to
        // the scroll edge effect and draws neither the effect nor the colour set here.
        appearance.configureWithOpaqueBackground()
        appearance.backgroundEffect = blur()
        appearance.backgroundColor = tint(color)
        appearance.shadowColor = .clear
    }
}

/// A frosted band: blur, the tint over it, and a fade over the edge that faces the content.
final class DesktopFrostView: UIView {
    enum Fade { case none, bottom, top }

    let effectView = UIVisualEffectView(effect: DesktopFrost.blur())
    private let tintView = UIView()
    private let fadeMask = CAGradientLayer()
    var fade: Fade = .none { didSet { setNeedsLayout() } }
    var fadeLength: CGFloat = 50 { didSet { setNeedsLayout() } }
    var color: UIColor = .clear { didSet { tintView.backgroundColor = DesktopFrost.tint(color, alpha: tintAlpha) } }
    /// The tint's alpha (a control on the frost, like the jump pill, is mostly its fill).
    var tintAlpha: CGFloat = DesktopFrost.tintAlpha { didSet { tintView.backgroundColor = DesktopFrost.tint(color, alpha: tintAlpha) } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        effectView.frame = bounds
        effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tintView.frame = bounds
        tintView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(effectView)
        addSubview(tintView)
        fadeMask.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard fade != .none, bounds.height > 0 else { layer.mask = nil; return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = bounds
        let solid = max(0, 1 - fadeLength / bounds.height)
        fadeMask.locations = [0, NSNumber(value: Double(solid)), 1]
        fadeMask.startPoint = CGPoint(x: 0.5, y: fade == .bottom ? 0 : 1)
        fadeMask.endPoint = CGPoint(x: 0.5, y: fade == .bottom ? 1 : 0)
        layer.mask = fadeMask
        CATransaction.commit()
    }
}
