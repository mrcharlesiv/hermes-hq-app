// [top-edge] Theme › Themes › Top Edge (owner 2026-11-03, a screenshot of Claude's app): where rows scroll under the
// top bar, the system's soft edge (the blur fades out going down, the bar has no bottom) or its hard edge (a frosted
// band the height of the bar, cut off on a straight line: "straight across in a rectangle"), the default since
// 2026-11-04. Every tab's still edge host (`ListBarAppearance.pinTitle(softEdgeAround:)`) draws it. Chats are always
// soft at both ends (owner 2026-11-05, [chat-soft-edge] in `ChatViewController`). The Mac draws no top edge (its bars have a backing
// instead), so it has no choice.

import UIKit

enum TopEdgeStyle {
    static var offered: Bool {
        #if targetEnvironment(macCatalyst)
        false
        #else
        true
        #endif
    }

    static var current: UIScrollEdgeEffect.Style {
        offered && Theme.shared.state.topEdge == .hard ? .hard : .soft
    }

    /// Sets `scroll`'s top edge to the chosen style now and again whenever the theme changes.
    static func follow(_ scroll: UIScrollView) {
        scroll.topEdgeEffect.style = current
        scroll.registerForTraitChanges([ThemeGenerationTrait.self]) { (scroll: UIScrollView, _) in
            let style = TopEdgeStyle.current
            if scroll.topEdgeEffect.style != style { scroll.topEdgeEffect.style = style }
        }
    }
}
