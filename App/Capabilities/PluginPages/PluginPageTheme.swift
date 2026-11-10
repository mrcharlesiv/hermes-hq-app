// [plugin-pages] The page plugin host's CSS variables from HQ's own palette (light/dark, the skin, the Desktop Look),
// read for the page's trait collection. scripts/plugin-host/host.css maps the dashboard's tokens onto them.

import UIKit

enum PluginPageTheme {
    static func css(_ traits: UITraitCollection) -> String {
        func css(_ color: UIColor, alpha: CGFloat? = nil) -> String {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            let clamp = { (v: CGFloat) in Int((min(max(v, 0), 1) * 255).rounded()) }
            return "rgba(\(clamp(r)),\(clamp(g)),\(clamp(b)),\(String(format: "%.3f", alpha ?? a)))"
        }
        let dark = traits.userInterfaceStyle == .dark
        let desktop = Theme.isDesktop
        let radius: Int = desktop ? 8 : (DeviceWord.isMac ? 12 : 20)
        let vars: [(String, String)] = [
            ("--hq-scheme", dark ? "dark" : "light"),
            ("--hq-bg", css(HQPalette.groupedPage)),
            ("--hq-card", css(HQPalette.card)),
            ("--hq-label", css(HQPalette.label)),
            ("--hq-label2", css(HQPalette.label2)),
            ("--hq-label3", css(HQPalette.label3)),
            ("--hq-separator", css(HQPalette.separator)),
            ("--hq-tint", css(HQPalette.tint)),
            ("--hq-on-tint", css(HQPalette.onTint)),
            ("--hq-fill", css(HQPalette.fill3)),
            ("--hq-segment", dark ? css(HQPalette.label, alpha: 0.2) : css(HQPalette.lifted)),   // the chosen tab; lifted is the card itself in dark
            ("--hq-red", css(HQPalette.red)),
            ("--hq-orange", css(HQPalette.orange)),
            ("--hq-green", css(UIColor.systemGreen)),
            // Floating chrome (a dialog, a toast) on glass: the card, see-through, with a thin edge (glass rule 5).
            ("--hq-glass", css(HQPalette.card, alpha: desktop ? 1 : 0.72)),
            ("--hq-glass-edge", dark ? "rgba(255,255,255,0.16)" : "rgba(0,0,0,0.08)"),
            ("--hq-radius", "\(radius)px"),
            ("--hq-card-border", desktop ? "1px solid \(css(HQPalette.stroke))" : "0 solid transparent"),
            ("--hq-page-pad", desktop || DeviceWord.isMac ? "20px" : "16px"),
            ("--hq-body-size", "\(Int(HQFont.scaled(15).rounded()))px"),
            // [mac] Mac polish #125: the Mac draws the page at 77 %, so the host's 12 px tags and labels came out at 9 pt.
            // Its small sizes don't go under the app's own smallest there (`HQFont.macSmallest`, 10 pt on screen).
            ("--hq-text-min", DeviceWord.isMac ? "\(Int(HQFont.macSmallest))px" : "0px"),
        ]
        return ":root{" + vars.map { "\($0.0):\($0.1);" }.joined() + "color-scheme:\(dark ? "dark" : "light");}"
    }
}
