// desktoplook: shapes and metrics that change with the Desktop Look (spec 3x-desktoplook §3.5, §5.1). Look off:
// the value passed in, untouched.

import SwiftUI
import UIKit

nonisolated enum HQShape {
    enum Role { case inline, control, card, bubble, field, capsule, tile, group, sheet }

    /// The desktop's corners (phone-ui-desktop.css:59-66).
    static func desktopRadius(_ role: Role) -> CGFloat {
        switch role {
        case .inline: 2
        case .control, .tile: 3
        case .card, .bubble, .field, .capsule, .group: 4
        case .sheet: 8
        }
    }

    /// `standard` with the look off; the desktop's corner for the role with it on.
    static func radius(_ standard: CGFloat, _ role: Role) -> CGFloat {
        ThemeTable.current.state.desktopLook ? min(standard, desktopRadius(role)) : standard
    }

    /// List and sheet gutter: 20 pt in the Desktop Look (phone-ui-desktop.css:349-351).
    static func gutter(_ standard: CGFloat) -> CGFloat { ThemeTable.current.state.desktopLook ? 20 : standard }

    static var hairline: CGFloat { 1 }

    /// The time under a message: replies only in the Desktop Look (phone-ui-desktop.css: your own box has none). The
    /// layout asks, so no room is kept for a time that is not drawn.
    static func showsTime(mine: Bool) -> Bool { !(mine && ThemeTable.current.state.desktopLook) }

    /// A reply in the Desktop Look has no bubble: its text sits on the page margin, with no padding kept for a bubble
    /// that is not drawn and no face column beside it (owner, 2026-10-14: the reply looked indented). High Contrast
    /// boxes it like your own message (owner, 2026-10-26), so it keeps the bubble's padding there.
    static var plainReplies: Bool {
        let state = ThemeTable.current.state
        return state.desktopLook && !state.contrastApplies
    }
}
