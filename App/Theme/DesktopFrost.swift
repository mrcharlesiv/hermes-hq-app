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
    /// [Mac glass 2026-11-17] The bars' and bands' own veil. On the Mac it carries the pop-overs' 94 % page veil over
    /// the frost. On iPhone and iPad it uses a 72 % skin-tinted veil over `.systemThinMaterial` (Crisp Frosted Chrome):
    /// genuinely translucent so scrolled rows breathe behind the bar, while preserving dark/colored skin hues and AA
    /// contrast over bold rows or chat bubbles. Selection colours and other `tint` users keep `tintAlpha`.
    static var barTintAlpha: CGFloat {
        #if targetEnvironment(macCatalyst)
        return 0.94
        #else
        #if DEBUG
        // `-HQDebugBarTintAlpha <0…1>`: the iPhone's and iPad's bar veil for a picture (choosing its value).
        if let debug = UserDefaults.standard.string(forKey: "HQDebugBarTintAlpha"), let value = Double(debug) {
            return CGFloat(value)
        }
        #endif
        return 0.72
        #endif
    }
    /// Docked bottom tab bar veil in the Hermes / Desktop Look: slightly denser than the top bar so 10 pt labels and
    /// badges stay crisp while list rows still diffuse softly behind the bar.
    static let tabBarTintAlpha: CGFloat = 0.76
    /// Whisper hairline framing frosted top and bottom bars (falls back to full `separator` under high contrast).
    static let whisperLine = UIColor { traits in
        if traits.accessibilityContrast == .high || ThemeTable.current.state.highContrast {
            return HQPalette.separator.resolvedColor(with: traits)
        }
        let alpha: CGFloat = traits.userInterfaceStyle == .dark ? 0.09 : 0.07
        return HQPalette.label.resolvedColor(with: traits).withAlphaComponent(alpha)
    }
    /// The blur under the tint (the system's plain blur, light and dark by itself; not glass).
    static func blur() -> UIBlurEffect {
        #if targetEnvironment(macCatalyst)
        UIBlurEffect(style: .regular)
        #else
        UIBlurEffect(style: .systemThinMaterial)
        #endif
    }

    /// `base` at the band's alpha, following the trait (light, dark, the skin).
    static func tint(_ base: UIColor, alpha: CGFloat = tintAlpha) -> UIColor {
        UIColor { traits in base.resolvedColor(with: traits).withAlphaComponent(alpha) }
    }

    /// A bar in the look (every state, sheets included): the same frost, no line.
    static func barAppearance(_ appearance: UINavigationBarAppearance, color: UIColor) {
        // Opaque's configuration, then made see-through: on iOS 26 the default configuration leaves the background to
        // the scroll edge effect and draws neither the effect nor the colour set here.
        let solid = HQAccessibility.reduceTransparency
        appearance.configureWithOpaqueBackground()
        appearance.backgroundEffect = solid ? nil : blur()
        appearance.backgroundColor = solid ? color : tint(color, alpha: barTintAlpha)
        appearance.shadowColor = .clear
    }
}

/// A frosted band: blur, the tint over it, and a fade over the edge that faces the content.
final class DesktopFrostView: UIView {
    enum Fade { case none, bottom, top }

    let effectView = UIVisualEffectView(effect: DesktopFrost.blur())
    private let tintView = UIView()
    /// The frost's own two layers end here: what a control on the frost draws goes over this (the jump pill's hover).
    var backing: UIView { tintView }
    private let fadeMask = CAGradientLayer()
    var fade: Fade = .none { didSet { setNeedsLayout() } }
    var fadeLength: CGFloat = 50 { didSet { setNeedsLayout() } }
    var color: UIColor = .clear { didSet { tintView.backgroundColor = DesktopFrost.tint(color, alpha: tintAlpha) } }
    /// The tint's alpha (a control on the frost, like the jump pill, is mostly its fill).
    var tintAlpha: CGFloat = DesktopFrost.barTintAlpha { didSet { tintView.backgroundColor = DesktopFrost.tint(color, alpha: tintAlpha) } }

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
