// [groups] A sender's name colour on a bubble (docs/spec/3x-groups.md §7.12): the bot's colour moved toward black
// (light) or white (dark) until it reads at 4.5:1 on the bubble; the label colour when it has none.

import UIKit

enum ChatSenderPalette {
    private static var cache: [String: UIColor] = [:]

    static func nameColor(hex: String?) -> UIColor {
        guard let hex, let pair = NameColor.readable(hex), let raw = NameColor.parse(hex) else { return .label }
        if let known = cache[hex] { return known }
        // [Mac UI check 2026-11-13] L15: at 4.5:1 a light hue (Ivy's butter) came out a weak mustard on the light grey
        // bubble; the light look's name is taken a little further toward black (6:1), the dark look's stays.
        let strong = NameColor.readable(raw, surface: NameColor.lightBubble, toward: NameColor.RGB(0, 0, 0), ratio: 6)
        let light = UIColor(red: strong.r / 255, green: strong.g / 255, blue: strong.b / 255, alpha: 1)
        let dark = UIColor(red: pair.dark.r / 255, green: pair.dark.g / 255, blue: pair.dark.b / 255, alpha: 1)
        let made = UIColor { $0.userInterfaceStyle == .dark ? dark : light }
        if cache.count > 256 { cache.removeAll() }
        cache[hex] = made
        return made
    }
}
