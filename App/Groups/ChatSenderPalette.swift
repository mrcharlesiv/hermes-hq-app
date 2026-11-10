// [groups] A sender's name colour on a bubble (docs/spec/3x-groups.md §7.12): the bot's colour moved toward black
// (light) or white (dark) until it reads at 4.5:1 on the bubble; the label colour when it has none.

import UIKit

enum ChatSenderPalette {
    private static var cache: [String: UIColor] = [:]

    static func nameColor(hex: String?) -> UIColor {
        guard let hex, let pair = NameColor.readable(hex) else { return .label }
        if let known = cache[hex] { return known }
        let light = UIColor(red: pair.light.r / 255, green: pair.light.g / 255, blue: pair.light.b / 255, alpha: 1)
        let dark = UIColor(red: pair.dark.r / 255, green: pair.dark.g / 255, blue: pair.dark.b / 255, alpha: 1)
        let made = UIColor { $0.userInterfaceStyle == .dark ? dark : light }
        if cache.count > 256 { cache.removeAll() }
        cache[hex] = made
        return made
    }
}
