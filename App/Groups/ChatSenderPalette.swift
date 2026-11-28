// [groups] A sender's name colour on a bubble (docs/spec/3x-groups.md §7.12): the bot's colour moved toward black
// (light) or white (dark) until it reads at 4.5:1 on the bubble; the label colour when it has none.

import UIKit

enum ChatSenderPalette {
    private static var cache: [String: UIColor] = [:]

    /// [theme review] Read against the skin's own bot bubble (over its page) at draw time, not the Nous greys, and the
    /// theme's label when there is no colour.
    static func nameColor(hex: String?) -> UIColor {
        guard let hex, NameColor.readable(hex) != nil, let raw = NameColor.parse(hex) else { return ChatPalette.label }
        if let known = cache[hex] { return known }
        let made = UIColor { @Sendable traits in
            func rgb(_ colour: UIColor) -> (NameColor.RGB, CGFloat) {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                colour.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
                return (NameColor.RGB(Double(r * 255), Double(g * 255), Double(b * 255)), a)
            }
            let (page, _) = rgb(ChatPalette.page)
            let (bubble, alpha) = rgb(ChatPalette.botBubble)
            let a = Double(alpha)
            let surface = NameColor.RGB(bubble.r * a + page.r * (1 - a), bubble.g * a + page.g * (1 - a), bubble.b * a + page.b * (1 - a))
            let black = NameColor.RGB(0, 0, 0), white = NameColor.RGB(255, 255, 255)
            let lightSurface = NameColor.contrast(black, surface) >= NameColor.contrast(white, surface)
            // [Mac UI check 2026-11-13] L15: at 4.5:1 a light hue (Ivy's butter) came out a weak mustard on a light
            // bubble; on a light bubble the name is taken a little further toward black (6:1).
            let made = NameColor.readable(raw, surface: surface, toward: lightSurface ? black : white, ratio: lightSurface ? 6 : 4.5)
            return UIColor(red: made.r / 255, green: made.g / 255, blue: made.b / 255, alpha: 1)
        }
        if cache.count > 256 { cache.removeAll() }
        cache[hex] = made
        return made
    }
}
