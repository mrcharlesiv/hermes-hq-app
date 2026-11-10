// [mac] The Mac sidebar's measuring rules as pure functions (App/Mac/MacSidebar.swift draws them), here so they are
// unit tested with the rest (Tests/MacPolish4Tests.swift). Mac polish round, 2026-11-07.

import CoreGraphics

nonisolated enum SidebarRules {
    /// How tall a list's fading edge grows (`MacSidebar.placeFade`).
    static let fadeHeight: CGFloat = 22

    /// Mac polish #51: where a list's mask turns solid from its top and starts to fade at its foot, as shares of its
    /// `height`, with `above` and `below` points of rows past its edges. A fade grows with the rows past it, up to
    /// `fadeHeight`, and never past half the list. nil: all in view, no mask.
    static func fadeStops(above: CGFloat, below: CGFloat, height: CGFloat) -> (top: CGFloat, bottom: CGFloat)? {
        guard height > 0, above > 1 || below > 1 else { return nil }
        let top = above > 1 ? min(above, fadeHeight) / height : 0
        let bottom = below > 1 ? 1 - min(below, fadeHeight) / height : 1
        return (min(top, 0.5), max(bottom, 0.5))
    }

    /// A row of the bots' list for `headingFade`: its top and foot in the list, and whether it is a group's heading.
    struct ListRow: Equatable, Sendable {
        var top: CGFloat
        var bottom: CGFloat
        var heading: Bool
    }

    /// After Mac polish #33 (Marketplace made the Tools one row longer): a list shown from `top`, `height` tall, with
    /// `below` points of rows past its foot, that would stop on a group's heading, cut by the fade or with the group's
    /// first row cut or faded under it (Unassigned over a ghost of Notes read as an empty group). Where its foot fade
    /// starts and where it is clear, in the list's visible height: across the heading, so the list ends on the row
    /// above it. nil: the usual fade (the last clear row a bot's, or everything in view).
    static func headingFade(rows: [ListRow], top: CGFloat, height: CGFloat, below: CGFloat) -> (start: CGFloat, end: CGFloat)? {
        guard height > 0, below > 1 else { return nil }
        let foot = top + height
        let clear = foot - min(below, fadeHeight)
        guard let cut = rows.firstIndex(where: { $0.bottom > clear && $0.top < foot }) else { return nil }
        // The heading cut by the fade, or the one over the first row it cuts.
        let index = rows[cut].heading ? cut : cut > 0 && rows[cut - 1].heading ? cut - 1 : nil
        guard let index, rows[index].top - headingLead > top else { return nil }
        let heading = rows[index]
        return (heading.top - headingLead - top, min(height, heading.bottom - headingLead - top))
    }
    /// How far above a lone heading its fade starts (and above its foot it is clear): the heading's words read faint.
    static let headingLead: CGFloat = 6

    /// Mac polish #54: how far a name drawn at `pointSize` may shrink to fit (`minimumScaleFactor`): `least`, but never
    /// under `smallest` (the Mac's smallest text, `HQFont.macSmallest`).
    static func shrink(pointSize: CGFloat, least: CGFloat, smallest: CGFloat) -> CGFloat {
        min(1, max(least, smallest / max(pointSize, 1)))
    }

    /// Mac polish #56: whether a colour read past the sidebar's edge (0–255 a channel) is the window not drawn yet rather
    /// than a page: pure black beside any page that isn't black, and in light mode anything near it (the iOS look
    /// light's folded rail got a near-black frame). A light page with a picture behind it (App Background, dimmed with
    /// the page's colour) reads far lighter.
    /// `picture`: an App Background picture shows beside it, so a near-black read can be the picture itself (a very dark
    /// photo at low dimming), and only pure black still means not drawn (Mac polish #56's leftover: the strip went white).
    static func undrawn(red: UInt8, green: UInt8, blue: UInt8, light: Bool, pageIsBlack: Bool, picture: Bool = false) -> Bool {
        guard !pageIsBlack else { return false }
        let most = max(red, green, blue)
        return most == 0 || (light && !picture && most < 48)
    }
}
