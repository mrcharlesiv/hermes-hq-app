// [mac] Stress test 2026-10-28 #52, #53, #9, #55, #58: the Mac's one set of page tokens. Text of one role, the page's
// edges, empty and error states, and icon columns were sized page by page (footers 10 to 15 pt, empty titles 15 to
// 28, sides 16, 20 or 24, icons of every weight). Every Mac page, UIKit or SwiftUI, in both looks, reads them here.
// Sizes are HQFont styles, so they follow the look's base and UI Scale as the rest of the Mac's text does. Nothing
// here changes the iPhone or iPad: the helpers that apply them are no-ops off the Mac.

import SwiftUI
import UIKit

/// [mac] #52: one font per text role.
@MainActor enum MacType {
    /// A page's title in its bar (the bar's own appearance draws it; see `MacWindow.pageBar`).
    static var pageTitle: UIFont { HQFont.preferred(.headline) }
    /// A section's header in the iOS look (the Desktop Look keeps its tracked capitals, `hqDesktopLabel`).
    static var sectionHeader: UIFont { HQFont.preferred(.subheadline).pagesWeight(.semibold) }
    /// A row's title.
    static var row: UIFont { HQFont.preferred(.body) }
    /// A row's value or subtitle.
    static var value: UIFont { HQFont.preferred(.subheadline) }
    /// A section's footer and any help line under a control.
    static var footnote: UIFont { HQFont.preferred(.footnote) }
    /// An empty or error state's title and its line.
    static var emptyTitle: UIFont { HQFont.preferred(.title3).pagesWeight(.semibold) }
    static var emptyBody: UIFont { HQFont.preferred(.subheadline) }
    /// An empty state's symbol: one size everywhere (was 23 to 44).
    static var emptySymbol: UIImage.SymbolConfiguration {
        UIImage.SymbolConfiguration(pointSize: HQFont.scaled(34), weight: .regular)
    }
    /// [mac] Stress test 2026-10-28 round 9: one height for every empty state's symbol, the detail placeholder's
    /// (`sidebar.right` at `emptySymbol`). At one point size the symbols still drew 35 to 40 pt tall (Jobs' clock was 40
    /// beside the placeholder's 35), which pushed the Jobs title down beside the placeholder's in the iOS look.
    static var emptySymbolHeight: CGFloat {
        ceil(UIImage(systemName: "sidebar.right", withConfiguration: emptySymbol)?.size.height ?? HQFont.scaled(34))
    }

    // SwiftUI twins.
    static var sectionHeaderFont: Font { Font.hq(.subheadline).weight(.semibold) }
    static var rowFont: Font { Font.hq(.body) }
    static var valueFont: Font { Font.hq(.subheadline) }
    static var footnoteFont: Font { Font.hq(.footnote) }
    static var emptyTitleFont: Font { Font.hq(.title3).weight(.semibold) }
    static var emptyBodyFont: Font { Font.hq(.subheadline) }
    static var emptySymbolFont: Font { Font.system(size: HQFont.scaled(34), weight: .regular) }
}

/// [mac] #53: one page inset. Sides and the gap under the bar, for More pages, sheets, search fields over cards and the
/// chat's column; and how far above the middle an empty state sits.
nonisolated enum MacInset {
    static let side: CGFloat = 20
    static let top: CGFloat = 16
    /// The gap under the bar on the Mac; `otherwise` (the page's own) elsewhere.
    static func top(otherwise: CGFloat) -> CGFloat { DeviceWord.isMac ? top : otherwise }
    /// Room above a section header in the iOS look, so the footer before it doesn't run into it (#52).
    static let headerGap: CGFloat = 10
    /// Empty and error states are centred this far above the middle of the space they have (#9).
    static let emptyLift: CGFloat = 40
}

/// [mac] #58: one symbol size and weight per context, in a fixed-width column.
@MainActor enum MacIcon {
    /// A list row's leading glyph (More, Settings hubs): the size of the row's own text, regular weight.
    static var rowSize: CGFloat { HQFont.preferred(.body).pointSize }
    static var row: UIImage.SymbolConfiguration { UIImage.SymbolConfiguration(pointSize: rowSize, weight: .regular) }
    static var rowFont: Font { Font.system(size: rowSize, weight: .regular) }
    /// The column the row glyph is centred in, so titles start at one x whatever the symbol's width.
    static var rowColumn: CGFloat { (rowSize * 1.45).rounded() }
}

extension View {
    /// [mac] #9: an empty or error state that fills its space sits a little above the middle, the same on every page.
    /// Elsewhere: centred, as it was.
    @ViewBuilder func hqMacEmptyPlacement() -> some View {
        #if targetEnvironment(macCatalyst)
        self.padding(.bottom, 2 * MacInset.emptyLift)
        #else
        self
        #endif
    }
}

extension View {
    /// [mac] #9: an empty or error state drawn as a row under a list's Bot picker (Messaging) stood near the top in a
    /// 380 pt row. On the Mac it takes the list's height less the picker's card, so it sits where the page's own state
    /// would; elsewhere the fixed `minHeight` it had. `above`: about how tall the rows over it are.
    /// [mac] Stress test 2026-10-28 #9 (round 2): the row draws no box in the Desktop Look either (it read as a card
    /// near the top on Messaging and Import Sessions, while the iOS look had none).
    @ViewBuilder func hqListedEmptyState(minHeight: CGFloat, above: CGFloat = 160) -> some View {
        #if targetEnvironment(macCatalyst)
        self.modifier(MacListedEmptyHeight(minHeight: minHeight, above: above))
            .listRowBackground(Color.clear)
            .hqDesktopBareRow()
        #else
        self.frame(minHeight: minHeight)
        #endif
    }

    /// [mac] Stress test 2026-10-28 round 7: tells the rows of this List how tall it is, for `hqListedEmptyState`. Inside
    /// a List a row's `containerRelativeFrame` doesn't get the list's height, so Import Sessions' state kept its 280 pt
    /// minimum and stood a third of the way down while the pages laid out without a List were centred. Elsewhere nothing.
    @ViewBuilder func hqMacListHeight() -> some View {
        #if targetEnvironment(macCatalyst)
        modifier(MacListHeightReader())
        #else
        self
        #endif
    }

    /// [mac] Stress test 2026-10-28 #9: `hqListedEmptyState` on the Mac only (a page whose iPhone layout has no
    /// fixed height for the row, as Prompts). Elsewhere nothing.
    @ViewBuilder func hqMacListedEmptyState(above: CGFloat) -> some View {
        #if targetEnvironment(macCatalyst)
        self.hqListedEmptyState(minHeight: 280, above: above)
        #else
        self
        #endif
    }
}

extension View {
    /// [mac] #55: a segmented control's row in a List, placed one way on every page: a section of its own with no card,
    /// edge to edge at the cards' width in both looks (round 7: no Desktop Look outline round it). Elsewhere the row
    /// keeps the insets its page gave it (`otherwise`).
    @ViewBuilder func hqSegmentRow(otherwise insets: EdgeInsets) -> some View {
        if DeviceWord.isMac {
            // [mac] Stress test 2026-10-28 round 7: the Desktop Look outlined the segments' section as a card, so the
            // bordered strip sat in a second bordered frame (Import Sessions; Command Center while it had tabs). The row is now bare in
            // both looks: the strip stands on the page at the cards' width, as the iOS look's does.
            self.listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                .hqDesktopBareRow()
        } else {
            self.listRowBackground(Color.clear).listRowInsets(insets)
        }
    }
}

extension UIListContentConfiguration {
    /// [mac] Stress test 2026-10-28 #52: a UIKit list's section header (More, its search results, Artifacts, Kanban,
    /// the Models and Commands sheets, the slash drawer) in the iOS look on the Mac: the section-header token in
    /// label-2, as typed, so the UIKit headers match the SwiftUI pages' (`DesktopLayout`). The Desktop Look keeps its
    /// tracked capitals; the iPhone and iPad keep each header as it was.
    @MainActor func hqMacSectionHeader() -> UIListContentConfiguration {
        guard DeviceWord.isMac, !Theme.isDesktop, attributedText == nil else { return self }
        var copy = self
        copy.textProperties.font = MacType.sectionHeader
        copy.textProperties.color = HQPalette.label2
        copy.textProperties.transform = .none
        return copy
    }
}

/// [mac] #52: a SwiftUI section footer. On the Mac the footnote token (a hosted page's default font is the scaled
/// body, which made footers as big as the rows above them); elsewhere its content as it was.
struct HQSectionFooter<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        #if targetEnvironment(macCatalyst)
        // [mac] Stress test 2026-10-28 #106: in the Desktop Look the look's own secondary text (kept at 4.5:1 or better
        // on its page, `ThemeResolver.desktop`), not the system's dimmer grey on near-black.
        // [mac] Stress test 2026-10-28 round 8: the iOS look too. The system's footer grey was 117 on the 236 page,
        // 3.9:1; the look's secondary label colour reads at about 7:1 there. HQPalette is unchanged, as is the iPhone.
        let _ = Theme.touch()
        content.font(MacType.footnoteFont).foregroundStyle(Color.hqLabel2)
        #else
        // [ui-sizing] A footnote, not the page's scaled body (`HQListText`): iOS's own at a UI Scale, the look's in the
        // Desktop Look; nothing set at 100 % in the iOS look.
        content.font(HQListText.scaledRoot ? (Theme.isDesktop ? .hq(.footnote) : HQListText.footer) : nil)
        #endif
    }
}

/// [mac] Stress test 2026-10-28 round 7: a list's empty state and the detail pane's placeholder beside it put their
/// titles 9 to 18 pt apart: the placeholder holds its title at `MacInset.emptyLift` above the middle, the lists centred
/// their whole symbol-title-text stack, so a two-line text or a button moved the list's title. On the Mac a list's
/// state now holds its title there too. `parts`: the room above the title (the symbol and its gap), the title's height
/// and the room under it (the text, buttons) at `width`, from the configuration's own fonts and gaps.
@MainActor enum MacEmptyTitle {
    static func parts(_ config: UIContentUnavailableConfiguration, width: CGFloat) -> (above: CGFloat, title: CGFloat, below: CGFloat) {
        func height(_ text: String?, _ font: UIFont) -> CGFloat {
            guard let text, !text.isEmpty, width > 0 else { return 0 }
            let box = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                      options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                      attributes: [.font: font], context: nil)
            return ceil(box.height)
        }
        var above: CGFloat = 0
        if let image = config.image {
            let sized = config.imageProperties.preferredSymbolConfiguration.flatMap { image.applyingSymbolConfiguration($0) } ?? image
            // [mac] Stress test 2026-10-28 round 9: as tall as the state draws it, under its maximum height.
            let most = config.imageProperties.maximumSize.height
            above = ceil(most > 0 ? min(sized.size.height, most) : sized.size.height) + config.imageToTextPadding
        }
        let title = height(config.text, config.textProperties.font)
        var below: CGFloat = 0
        var secondary = height(config.secondaryText, config.secondaryTextProperties.font)
        if secondary == 0, let styled = config.secondaryAttributedText, width > 0 {   // [mac-ui-issues] Tiles' how-to lines
            secondary = ceil(styled.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                 options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
        }
        if secondary > 0 { below += config.textToSecondaryTextPadding + secondary }
        if config.button.title != nil {
            let button = config.button
            below += config.textToButtonPadding + ceil(UIButton(configuration: button).intrinsicContentSize.height)
        }
        if config.secondaryButton.title != nil {
            let button = config.secondaryButton
            below += config.buttonToSecondaryButtonPadding + ceil(UIButton(configuration: button).intrinsicContentSize.height)
        }
        return (above, title, below)
    }

    /// A list's own `contentUnavailableConfiguration` (centred by the system in its view's safe area less its margins),
    /// with top and bottom margins that put its title's middle `MacInset.emptyLift` above the safe area's middle, as the
    /// placeholder's is. The margins start from a fresh configuration's, so placing it again changes nothing.
    static func placed(_ config: UIContentUnavailableConfiguration, in view: UIView) -> UIContentUnavailableConfiguration {
        let base = UIContentUnavailableConfiguration.empty().directionalLayoutMargins
        var copy = config
        // [mac] Stress test 2026-10-28 round 9: the text runs the list's width less the rows' side room (20), not the
        // state's own 24 a side: "Jobs run a prompt on a schedule." needed 273 of a laptop pane's 272 and wrapped to
        // leave "a schedule." alone.
        copy.directionalLayoutMargins.leading = MacInset.side
        copy.directionalLayoutMargins.trailing = MacInset.side
        let margins = copy.directionalLayoutMargins
        let width = view.bounds.inset(by: view.safeAreaInsets).width - margins.leading - margins.trailing
        let parts = parts(copy, width: width)
        // The margins box's middle sits (top − bottom) / 2 below the safe area's, and the title's middle sits
        // (above − below) / 2 below the box's; together they come to −lift.
        let gap = parts.below - parts.above - 2 * MacInset.emptyLift
        copy.directionalLayoutMargins.top = base.top + max(0, gap)
        copy.directionalLayoutMargins.bottom = base.bottom + max(0, -gap)
        return copy
    }
}

extension UIViewController {
    /// [mac] Round 7: places the page's empty state's title as the detail placeholder's (`MacEmptyTitle.placed`). Call
    /// from `viewDidLayoutSubviews`; nothing off the Mac or without a state.
    func hqPlaceMacEmptyTitle() {
        guard DeviceWord.isMac, view.bounds.width > 0,
              let config = contentUnavailableConfiguration as? UIContentUnavailableConfiguration else { return }
        let placed = MacEmptyTitle.placed(config, in: view)
        guard placed.directionalLayoutMargins != config.directionalLayoutMargins else { return }
        contentUnavailableConfiguration = placed
    }
}

#if targetEnvironment(macCatalyst)
private struct MacListHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// [mac] Round 7: the height of the List this row is in, when the page measured it (`hqMacListHeight`); 0 otherwise.
    var hqMacListHeight: CGFloat {
        get { self[MacListHeightKey.self] }
        set { self[MacListHeightKey.self] = newValue }
    }
}

private struct MacListHeightReader: ViewModifier {
    @State private var height: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .environment(\.hqMacListHeight, height)
    }
}

/// [mac] Round 7: an empty state's row as tall as the List's room under the rows above it (`above`), when the List said
/// its height; else the container-relative frame it had.
private struct MacListedEmptyHeight: ViewModifier {
    var minHeight: CGFloat
    var above: CGFloat
    @Environment(\.hqMacListHeight) private var list

    func body(content: Content) -> some View {
        if list > 0 {
            content.frame(height: max(minHeight, list - above))
        } else {
            content.containerRelativeFrame(.vertical) { height, _ in max(minHeight, height - above) }
        }
    }
}
#endif
