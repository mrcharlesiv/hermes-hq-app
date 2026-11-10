// [m9/ipad] One pane or two (docs/spec/3x-ipad.md §4.2). The rule is the web app's phone query
// (`src/ui-kit/phone.ts`: phone layout at max-width 767px, or at max-height 500px) applied to the window's own size,
// so Split View, Slide Over and Stage Manager windows follow it. Pure: unit tested in Tests/IPad.

import CoreGraphics

nonisolated enum PaneLayout: Equatable, Sendable {
    /// The phone layout.
    case single
    /// Two panes, the list pane this wide.
    case double(sidebar: CGFloat)

    /// Two panes need a window at least this wide…
    static let minWidth: CGFloat = 768
    /// …and taller than this.
    static let minHeight: CGFloat = 500
    /// The list pane: as wide as a phone (375 pt) whenever the chat beside it keeps the web's 448 px minimum, narrowing
    /// to 320 pt at the 768 pt edge (768 − 320 = 448). UX study 2026-10-19: a flat 320 pt below 1000 pt (an 820 pt
    /// portrait iPad) was narrower than any iPhone, so row subtitles cut harder at Extra Large text than on a phone.
    static let narrowSidebar: CGFloat = 320, wideSidebar: CGFloat = 375, chatMinWidth: CGFloat = 448
    /// [mac] The Mac's list pane is dragged to the width it wants (`preferred`), kept between the narrow width, this
    /// and what leaves the chat its minimum.
    static let widestSidebar: CGFloat = 640

    static func decide(size: CGSize, pad: Bool, preferred: CGFloat? = nil, foldable: Bool = false) -> PaneLayout {
        guard pad else { return .single }
        let width = size.width.rounded(.down), height = size.height.rounded(.down)
        // [duo] The open screen held upright (669 pt) shows the list beside the chat too, as Hermes Agent does.
        if foldable, width >= foldOpenMinWidth, width < minWidth, height > minHeight { return .double(sidebar: foldSidebar) }
        guard width >= minWidth, height > minHeight else { return .single }
        guard let preferred else { return .double(sidebar: min(wideSidebar, max(narrowSidebar, width - chatMinWidth))) }
        return .double(sidebar: max(narrowSidebar, min(preferred.rounded(), widestSidebar, width - chatMinWidth)))
    }

    var isDouble: Bool { if case .double = self { return true } else { return false } }
    var sidebar: CGFloat { if case .double(let width) = self { return width } else { return 0 } }

    /// The right pane's width in panes `width` wide, as the split cuts it: the list and the line between them out, or
    /// all of it beside a list folded away (no line there). One pane: the whole width.
    func detailWidth(panes width: CGFloat, pixel: CGFloat) -> CGFloat {
        guard case .double(let list) = self, list > 0 else { return width }
        return width - list - pixel
    }

    /// [mac-layout] The Mac's inspector (⌘I) takes `inspector` points at the window's trailing edge beside a chat only
    /// when what is left keeps the panes as they are: two panes beside an open list, the chat its minimum beside a list
    /// folded into the sidebar. Taken anyway, it turned two panes into one, which took the chat away from it, which gave
    /// the room back: the window flipped between the two (Mac polish #1).
    static func inspectorFits(panes: CGSize, inspector: CGFloat, listFolded: Bool) -> Bool {
        let rest = CGSize(width: panes.width - inspector, height: panes.height)
        return listFolded ? rest.width.rounded(.down) >= chatMinWidth : decide(size: rest, pad: true).isDouble
    }

    /// [duo] An open foldable upright (Duo: 669 pt) gets two panes from this width, the list this wide.
    static let foldOpenMinWidth: CGFloat = 640, foldSidebar: CGFloat = 300

    /// [duo] The widest iPhone that does not fold, upright (Pro Max: 440 pt), with room to spare.
    static let widestFlatPhone: CGFloat = 450

    /// [duo] An iPhone that unfolds (iPhone Duo, 2026: 466×678 pt folded, 626×890 pt open) gets the iPad's root, which
    /// must be in place before the first unfold. Told by its screen's narrow side: even folded it is wider than any
    /// iPhone that does not fold. Apple has not said which idiom or model name the Duo reports.
    static func foldable(screen: CGSize) -> Bool {
        min(screen.width, screen.height).rounded(.down) > widestFlatPhone
    }

    /// [duo] The Duo's model (Xcode's Duo simulator profile). Its size alone missed it: an app built with an SDK older
    /// than 27.1 stays out of the 80 pt sensor column, so folded its screen is 386 pt across, under `widestFlatPhone`,
    /// and a tester's Duo launched folded kept the phone root, one pane even open and sideways (2026-11-07).
    static let foldableModels: Set<String> = ["iPhone19,4"]

    /// [duo] This iPhone unfolds: its model, its screen, or it has been seen open before (`seenOpen`).
    static func foldable(model: String, screen: CGSize, seenOpen: Bool) -> Bool {
        foldableModels.contains(model) || foldable(screen: screen) || seenOpen
    }

    /// [duo] A foldable's screen is its open one (Duo: 669 pt across, folded 466 pt). The open screen turns every way,
    /// as an iPad's does; the Duo simulator keeps a portrait-only app upright on it, so sideways never had two panes.
    static func unfolded(screen: CGSize) -> Bool {
        min(screen.width, screen.height).rounded(.down) > 600
    }
}

/// The widest a chat's column of text gets in a wide pane (§4.6): prose past this is hard to read.
nonisolated enum ReadableColumn {
    /// [mac] 1280 on the Mac: Grok Bot's chat column, 960 pt on the screen at 77 % (owner 2026-10-27). Replies still
    /// stop at today's 728 (`ChatMetrics.replyMaxWidth`); your messages and the composer reach the column's edges.
    static var maxWidth: CGFloat {
        #if targetEnvironment(macCatalyst)
        1280
        #else
        760
        #endif
    }
    /// The column's width in a pane, and the margin on each side of it.
    static func fit(pane: CGFloat) -> (width: CGFloat, margin: CGFloat) {
        let width = min(pane, maxWidth)
        return (width, ((pane - width) / 2).rounded(.down))
    }
}
