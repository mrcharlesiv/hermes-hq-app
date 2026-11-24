// The Nous skin's colours for the lists and sign-in (spec 06 §1.2). One place, so other skins can follow later.

import SwiftUI
import UIKit

enum HQPalette {
    // [desktoplook] Every colour reads the live theme (App/Theme): the Nous values below are the defaults the resolver
    // returns with no skin picked and the Desktop Look off (HermesKit/Theme/ThemeTokens.swift `base`), so nothing
    // changes for someone who never opens Settings > Theme. The providers are `@Sendable` and nonisolated: SwiftUI
    // resolves these colours off the main thread when it renders asynchronously (a spinner, a sheet's animation, Edit
    // Head's page); a main-actor provider closure trapped there (EXC_BREAKPOINT in New Task).
    /// Page / list background.
    static let page = ThemedColor.make(\.page)
    static let label = ThemedColor.make(\.label)
    static let label2 = ThemedColor.make(\.label2)
    /// [paper-icons] A row icon's tile in a skin with ink icons (`Theme.inkIcons`).
    static let iconTile = ThemedColor.make(\.iconTile)
    static let label3 = ThemedColor.make(\.label3)
    static let tint = ThemedColor.make(\.tint)
    /// [message-colour] The Mac's chosen row: the tint, or the message colour picked on Chat Bubbles.
    static let chosenRow = ThemedColor.make(\.chosenRow)
    /// Tint as small text (times on unread rows).
    static let tintText = ThemedColor.make(\.tintText)
    static let separator = ThemedColor.make(\.separator)
    #if targetEnvironment(macCatalyst)
    /// [mac] Stress test 2026-10-28 #26: the lines between the sidebar, the list and the chat. The Desktop Look's
    /// separator is its navy card outline, which as a full-height pane divider read as a light blue rule; a Mac's split
    /// view divider is a neutral grey. The iOS look keeps its separator (already grey).
    static let paneLine = UIColor { @Sendable traits in
        let desktop = ThemeTable.withSet(generation: traits[ThemeGenerationTrait.self]) { $0.state.desktopLook }
        guard desktop else { return separator.resolvedColor(with: traits) }
        return traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.1) : UIColor(white: 0, alpha: 0.12)
    }
    #endif
    static let fill3 = ThemedColor.make(\.fill3)
    static let cellPressed = ThemedColor.make(\.cellPressed)
    /// An inset-grouped card on the page colour (verify round 3: the system's white card vanished on the #FEFEFE page in
    /// light; dark keeps the system's #1C1C1E).
    static let groupedCard = ThemedColor.make(\.groupedCard)
    /// A long-pressed row or tile, lifted over the dimmed page (the system's preview card: white, #1C1C1E in dark).
    static let lifted = ThemedColor.make(\.lifted)
    static let searchFill = ThemedColor.make(\.searchFill)
    /// Orange text (needs you) and the needs-you badge.
    static let orange = ThemedColor.make(\.orange)
    static let red = ThemedColor.make(\.red)
    static let muted = ThemedColor.make(\.muted)
    /// [desktoplook] Outlines in the Desktop Look (the separator colour otherwise).
    static let stroke = ThemedColor.make(\.strokeSecondary)
    /// [desktoplook] Text or a glyph on the tint.
    static let onTint = ThemedColor.make(\.onTint)
    /// [desktoplook] The page behind grouped lists (More, Settings, forms, sheets): use it wherever
    /// `HQPalette.groupedPage` would go. It IS that system colour until a skin with its own page is picked.
    static let groupedPage = ThemedColor.makeGroupedPage()
    /// A card on the grouped page: iOS's own card until a skin with its own page is picked, then the skin's card in
    /// the page's hue. Use it wherever `.secondarySystemGroupedBackground` would go.
    static let card = ThemedColor.makeGroupedCard()
    /// A plain (not grouped) full page, as the Browser and Screen viewers: iOS's own background until a skin with its
    /// own page is picked (or the Desktop Look), then the skin's page; it stayed black or white on a coloured skin.
    static let plainPage = UIColor { @Sendable traits in
        // [mac-audit] #8: the Mac's dark system background is a neutral grey too (`ThemedColor.macDarkGrouped`).
        guard ThemedColor.paintsGroupedPage(traits) else { return UIColor.systemBackground.resolvedColor(with: traits) }
        return page.resolvedColor(with: traits)
    }
    /// [glass] The page of a half-height sheet: clear while the sheet sits on Liquid Glass (iPhone, iOS look, below
    /// full height: `SheetGlass`), so the glass shows around the rows' solid cards; the grouped page otherwise.
    static let sheetPage = UIColor { @Sendable traits in
        traits[GlassSheetTrait.self] ? .clear : groupedPage.resolvedColor(with: traits)
    }
    /// [glass] A sheet's card (a grouped row, a copy block, a step): solid off the glass (`solidSheetCard`); on Liquid
    /// Glass a frosted pane, so the glass and what is behind it show through and the thin edge (`glassEdge`) sets it
    /// apart. Owner 2026-11-01, of the solid cards: "I just don't like the hard colors (grey background) on the Liquid
    /// Glass pop up", then, of the frosted Steps cards, "that is better… tons of other places need the same treatment".
    /// Dark: a white veil (the dark card is the dark glass's own grey, 1.05:1, so thinning it changed nothing). Light:
    /// the white card at 55 %. A skin keeps its own card's hue, thinned.
    static let sheetCard = UIColor { @Sendable traits in
        guard traits[GlassSheetTrait.self] else { return solidSheetCard.resolvedColor(with: traits) }
        return glassPane.resolvedColor(with: traits)
    }
    /// The frosted card itself, for a surface that is always on glass (the model panel) whatever the trait says.
    static let glassPane = UIColor { @Sendable traits in
        if traits.userInterfaceStyle == .dark, ThemeTable.set(generation: traits[ThemeGenerationTrait.self]).groupedPageIsSystem {
            return UIColor(white: 1, alpha: 0.07)
        }
        return solidSheetCard.resolvedColor(with: traits).withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.4 : 0.55)
    }
    /// [glass] iOS's raised card colour, always opaque: inside a glass sheet iOS resolves its card colours see-through
    /// and the chat's bubbles behind then tinted the values (verification round 3), so this resolves it without the
    /// sheet's glass. A sheet's card off the glass; what `sheetCard` thins on it.
    static let solidSheetCard = UIColor { @Sendable traits in
        // A skin's own card is a plain opaque colour: glass cannot thin it.
        // [mac-audit] #8: and the Mac's dark card in the page's hue (`ThemedColor.macDarkGrouped`).
        guard !ThemedColor.paintsGroupedPage(traits) else { return card.resolvedColor(with: traits) }
        let plain = UITraitCollection { t in
            t.userInterfaceStyle = traits.userInterfaceStyle
            t.userInterfaceLevel = .elevated
            t.accessibilityContrast = traits.accessibilityContrast
        }
        return UIColor.secondarySystemGroupedBackground.resolvedColor(with: plain)
    }
    /// [glass-design] Secondary words standing on a sheet's glass itself (an empty state's line): the primary label
    /// while the sheet sits on glass, where label 2 measured 3.2:1 over the blurred chat; label 2 off the glass.
    static let glassInk2 = UIColor { @Sendable traits in
        (traits[GlassSheetTrait.self] ? label : label2).resolvedColor(with: traits)
    }
    /// [glass-design] A card that only exists on glass (How Voice Works' rows, a prompt's explanation): the solid card
    /// while the sheet sits on glass, nothing off it, so the page reads as it always did there.
    static let glassCard = UIColor { @Sendable traits in
        traits[GlassSheetTrait.self] ? sheetCard.resolvedColor(with: traits) : .clear
    }
    /// [glass-design] The thin edge of a solid card standing on Liquid Glass: white 12 % in dark, black 6 % in light.
    /// The dark card measured 1.05:1 against the dark glass, so without it the cards ran into the glass (owner
    /// 2026-11-01, the Steps sheet, then every glass sheet's cards).
    static let cardEdge = UIColor { @Sendable traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 0, alpha: 0.06)
    }
    /// [glass-design] `cardEdge` while the sheet sits on glass; nothing off it (full height, the iPad, the Desktop Look,
    /// the Mac), where the cards stand on an opaque page that already sets them apart.
    static let glassEdge = UIColor { @Sendable traits in
        traits[GlassSheetTrait.self] ? cardEdge.resolvedColor(with: traits) : .clear
    }
    /// [glass-design] A code block on a sheet's card: on the glass a shade over the frosted card, not a solid slab; the
    /// code card's own fill off it.
    static let sheetCode = UIColor { @Sendable traits in
        guard traits[GlassSheetTrait.self] else { return ChatPalette.codeFill.resolvedColor(with: traits) }
        return glassCode.resolvedColor(with: traits)
    }
    /// The code block's shade on a surface that is always on glass.
    static let glassCode = UIColor { @Sendable traits in
        UIColor(white: 0, alpha: traits.userInterfaceStyle == .dark ? 0.22 : 0.045)
    }
    /// [glass-design] A sheet's card colour while it sits on glass, `other` off it (the Prompt editor keeps its own card
    /// colour at full height and in the Desktop Look).
    static func sheetCard(orOffGlass other: UIColor) -> UIColor {
        UIColor { @Sendable traits in (traits[GlassSheetTrait.self] ? sheetCard : other).resolvedColor(with: traits) }
    }
    /// [glass-design] A sheet action's capsule (`hqSheetAction`): the solid card while it stands on the glass, where
    /// the card is what stands out; on anything opaque (a card, the page at full height or on the iPad) a card-coloured
    /// capsule disappears into it, so there it is the tint (or the red) at 12 %, as iOS's tinted buttons.
    static func sheetActionFill(destructive: Bool = false, onCard: Bool = false) -> UIColor {
        let ink = destructive ? red : tint
        return UIColor { @Sendable traits in
            if traits[GlassSheetTrait.self] && !onCard { return sheetCard.resolvedColor(with: traits) }
            return ink.resolvedColor(with: traits).withAlphaComponent(0.12)
        }
    }
    /// [glass-design] The faintest words on a sheet's card (Chat Info's "fixture", "Connected", a step's time, a field's
    /// placeholder): label 2 in the iOS look (label 3 measured 2.1:1 on the card); the Desktop Look keeps its label 3.
    static let cardNote = UIColor { @Sendable traits in
        let desktop = ThemeTable.withSet(generation: traits[ThemeGenerationTrait.self]) { $0.state.desktopLook }
        return (desktop ? label3 : label2).resolvedColor(with: traits)
    }
}

/// A tab's bar (Bots, Sessions, Jobs, Kanban, Artifacts, Pinned, More). Owner 2026-11-01: one top for every tab, the
/// chat's: in the iOS look the bar is clear in every state and the list's soft edge (`pinTitle(softEdgeAround:)`)
/// blurs rows out under it. The Desktop Look has no glass: its bar is the look's frost, as its pages' and sheets' are.
/// A list without a soft edge keeps the page-coloured bar (the web's list header, `src/phone-tabs.css:35,139`). Set on
/// each list's own navigation item, so a pushed chat keeps its bar-less glass look. Verification round 2: the hard
/// scroll edge drew a hairline and a two-tone band at rest, stayed see-through when scrolled, and clipped the large
/// title when a subtitle appeared.
nonisolated(unsafe) private var lookTitleKey: UInt8 = 0
nonisolated(unsafe) private var groupedBarKey: UInt8 = 0
nonisolated(unsafe) private var softBarKey: UInt8 = 0
nonisolated(unsafe) private var pictureBandKey: UInt8 = 0

enum ListBarAppearance {
    static func apply(to item: UINavigationItem) {
        let grouped = objc_getAssociatedObject(item, &groupedBarKey) != nil
        // [desktoplook] The look's frost, no hairline (App/Theme/ThemeChrome.swift). Over the page at rest it reads as
        // the page; rows scrolled under it blur.
        if Theme.isDesktop {
            let rest = ThemeChrome.solidBar(solid: true), scrolled = ThemeChrome.solidBar(solid: true)   // pinned: see `pinTitle`
            #if !targetEnvironment(macCatalyst)
            // [desktop-hard-edge] Owner 2026-11-15: every page's top as the chat's (build 1016): a list in its still host
            // (`pinTitle(softEdgeAround:)`) draws the system's hard edge in the look, so the bar itself is clear (its
            // own faint frost stopped above Sessions' chips and let rows read through).
            if objc_getAssociatedObject(item, &softBarKey) != nil {
                for bar in [rest, scrolled] {
                    bar.configureWithTransparentBackground()
                    bar.shadowColor = .clear
                }
            } else {
                for bar in [rest, scrolled] { DesktopFrost.barAppearance(bar, color: grouped ? HQPalette.groupedPage : HQPalette.page) }
            }
            #else
            for bar in [rest, scrolled] { DesktopFrost.barAppearance(bar, color: grouped ? HQPalette.groupedPage : HQPalette.page) }
            #endif
            // [mac] Stress test 2026-10-28 #57: the right pane's bars are the look's frost (`ThemeChrome.apply`) and the
            // list's were solid, so the two pane headers never matched. Owner 2026-11-01: the phone's tabs too, so a
            // tab's bar and a pushed page's are the same in the look (on the phone, the hard edge since 2026-11-15).
            #if targetEnvironment(macCatalyst)
            // [Mac UI check 2026-11-13] V17, owner: "Unify". On the Mac a list column's title (Sessions, Jobs, More) is
            // a page title like every other place's, bold at the left (`MacType.pageTitle`, the look's own face), not
            // the small capital label. Before the appearances are set: the item keeps copies.
            macTitle(rest, scrolled)
            #endif
            item.scrollEdgeAppearance = rest
            item.standardAppearance = scrolled
            item.compactAppearance = scrolled
            item.compactScrollEdgeAppearance = rest
            // Unified with Mac V17: tab root titles stay readable Title Case (17 pt semibold) instead of 12 pt caps.
            dropLookTitle(item)
            return
        }
        // [desktoplook2] Only a title the look set is cleared: the getter answers non-nil for a plain title, and nil-ing it wipes the title.
        if let plain = objc_getAssociatedObject(item, &lookTitleKey) as? String {
            item.attributedTitle = nil
            item.title = plain
            objc_setAssociatedObject(item, &lookTitleKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        // A list with a soft edge (`pinTitle(softEdgeAround:)`): the bar is clear, as a chat's is, and rows fade
        // under it (owner, build 331: the solid band cut the top off the pinned bots' heads).
        if objc_getAssociatedObject(item, &softBarKey) != nil {
            let clear = UINavigationBarAppearance()
            clear.configureWithTransparentBackground()
            macTitle(clear)
            BackdropBarInk.paint(clear, for: item)   // [backdrop-ink] over the app's picture: the ink that reads on it
            item.scrollEdgeAppearance = clear
            item.standardAppearance = clear
            item.compactAppearance = clear
            item.compactScrollEdgeAppearance = clear
            return
        }
        // [backdrop] Theme › App Background: a copy of the picture is the band (`PageBackdrop`), so the bar is clear.
        if objc_getAssociatedObject(item, &pictureBandKey) != nil {
            let clear = UINavigationBarAppearance()
            clear.configureWithTransparentBackground()
            macTitle(clear)
            BackdropBarInk.paint(clear, for: item)   // [backdrop-ink]
            item.scrollEdgeAppearance = clear
            item.standardAppearance = clear
            item.compactAppearance = clear
            item.compactScrollEdgeAppearance = clear
            return
        }
        // The bar stays in its resting state (`pinTitle`), so it is the page colour there too: rows scroll under it.
        let rest = UINavigationBarAppearance()
        rest.configureWithOpaqueBackground()
        rest.backgroundColor = grouped ? HQPalette.groupedPage : HQPalette.page
        rest.shadowColor = .clear
        let scrolled = UINavigationBarAppearance()
        scrolled.configureWithOpaqueBackground()
        scrolled.backgroundColor = grouped ? HQPalette.groupedPage : HQPalette.page
        scrolled.shadowColor = HQPalette.separator
        macTitle(rest, scrolled)
        item.scrollEdgeAppearance = rest
        item.standardAppearance = scrolled
        item.compactAppearance = scrolled
        item.compactScrollEdgeAppearance = rest
        #if targetEnvironment(macCatalyst)
        // [mac] Stress test 2026-10-28 #57: one bar in every state. The hairline came and went with the list's scroll
        // state (and after Read Replies Aloud or Export), while the right pane's bars (`MacWindow.pageBar`) have none.
        item.standardAppearance = rest
        item.compactAppearance = rest
        #endif
    }

    /// A pushed page that pins its list (`pinTitle`) but isn't a tab root: the plain title, not the Desktop Look's
    /// tab label ("TASKS" at 12 pt beside other pages' 17 pt titles, owner 2026-11-04).
    static func dropLookTitle(_ item: UINavigationItem) {
        guard let plain = objc_getAssociatedObject(item, &lookTitleKey) as? String else { return }
        item.attributedTitle = nil
        item.title = plain
        objc_setAssociatedObject(item, &lookTitleKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// [backdrop] A tab's list whose title sits on a band of the page colour (not the soft edge's clear bar): with App
    /// Background on, the band is a copy of the picture instead (`PageBackdrop`).
    static func hasBand(_ item: UINavigationItem) -> Bool { objc_getAssociatedObject(item, &softBarKey) == nil }

    /// [backdrop-ink] Whether `item`'s bar is drawn here (a tab's pinned title: `pinTitle`), so a change to its ink
    /// goes through `apply`.
    static func owns(_ item: UINavigationItem) -> Bool {
        objc_getAssociatedObject(item, &softBarKey) != nil || objc_getAssociatedObject(item, &groupedBarKey) != nil
    }

    /// [backdrop] The picture's band shows behind the bar (clear) or not (the page colour again).
    static func setPictureBand(_ shows: Bool, on item: UINavigationItem) {
        let was = objc_getAssociatedObject(item, &pictureBandKey) != nil
        guard was != shows else { return }
        objc_setAssociatedObject(item, &pictureBandKey, shows ? true : nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        apply(to: item)
    }

    static func showsPictureBand(_ item: UINavigationItem) -> Bool { objc_getAssociatedObject(item, &pictureBandKey) != nil }

    /// [mac] The bar's title follows UI Scale with the page's rows; the system's 17 pt carries none, so Kanban's read
    /// smaller than Settings' (stress test 2026-10-28).
    /// [mac] Stress test 2026-10-28 #50: a tab's own title (the inline large title) is a toolbar title too, the same
    /// size as a page's (about 15 pt on the screen), not iOS's 34 pt.
    private static func macTitle(_ appearances: UINavigationBarAppearance...) {
        #if targetEnvironment(macCatalyst)
        for appearance in appearances {
            appearance.titleTextAttributes[.font] = MacType.pageTitle   // [mac] Stress test 2026-10-28 #52
            appearance.largeTitleTextAttributes[.font] = MacType.pageTitle
            // [Mac UI check 2026-11-13] The label colour, as `MacPlaceTitle`'s titles (the look's own ink).
            appearance.titleTextAttributes[.foregroundColor] = HQPalette.label
            appearance.largeTitleTextAttributes[.foregroundColor] = HQPalette.label
        }
        #endif
    }

    /// A tab root's title and gateway line stay where they are while the list scrolls (owner, build 284–286: the title
    /// moved to the centre with two arrows, then left an empty bar behind). The bar follows a still scroll view (as
    /// the chat's bar does, `edgeHost`), so it never collapses to the centred compact title; rows scroll under it.
    /// `grouped`: the page is the grouped page colour (More), and the bar matches it.
    /// `softEdgeAround`: the list goes inside the still scroll view, which draws the system's soft top edge over it
    /// (the chat's `edgeHost`), and the bar is clear: rows fade under the title instead of being cut off by a band.
    /// Every tab passes its list (owner 2026-11-01: one top for every tab).
    static func pinTitle(in controller: UIViewController, grouped: Bool = false, softEdgeAround list: UIScrollView? = nil) {
        if grouped {
            objc_setAssociatedObject(controller.navigationItem, &groupedBarKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            apply(to: controller.navigationItem)
        }
        if let list {
            objc_setAssociatedObject(controller.navigationItem, &softBarKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            apply(to: controller.navigationItem)
            let host = EdgeHostScrollView(frame: controller.view.bounds)
            host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.isScrollEnabled = false
            host.contentInsetAdjustmentBehavior = .never
            host.showsVerticalScrollIndicator = false
            host.scrollsToTop = false
            host.clipsToBounds = false
            TopEdgeStyle.follow(host)          // [top-edge] Theme › Themes › Top Edge: hard, or soft (hard in the look)
            #if !targetEnvironment(macCatalyst)
            DesktopEdges.leaveAlone(host)      // [desktop-hard-edge] the look keeps this edge: it is the hard band
            #endif
            host.bottomEdgeEffect.isHidden = true      // the list keeps its own fade under the tab bar
            list.topEdgeEffect.isHidden = true         // the host draws the top one
            controller.view.insertSubview(host, belowSubview: list)
            list.frame = host.bounds
            host.addSubview(list)
            host.watch(list, page: grouped ? HQPalette.groupedPage : HQPalette.page)
            controller.setContentScrollView(host, for: .top)
            return
        }
        let still = UIScrollView()
        still.isScrollEnabled = false
        still.isUserInteractionEnabled = false
        still.scrollsToTop = false
        still.isHidden = true
        controller.view.addSubview(still)
        controller.setContentScrollView(still, for: .top)
    }
}

/// The still scroll view a soft-edged list sits in: never scrolls, its content exactly its size.
/// Owner 2026-11-01: every tab's top is the chat's, a clear bar over the system's soft edge, with nothing painted. The
/// page-coloured band Bots had (owner 2026-10-30: rows ran straight through the title, the gateway line and the
/// buttons) read as a solid block over the pinned bots' heads, and no other tab had it. Instead the soft edge reaches
/// the whole header (the bar, and whatever sits in the safe area under it, as Sessions' chips) and, once rows scroll
/// under, `reachBelow` past it, so rows are blurred out before they meet the title. The chat's `topEdgeElement` does
/// the same past its status line.
/// [mac] The Mac draws no soft edge (stress test 2026-10-31 #1): there a backing in the page's colour behind the bar,
/// fading out 16 pt below it, comes in once rows scroll under, as the chat's `barBacking`.
private final class EdgeHostScrollView: UIScrollView {
    /// The region the soft top edge covers: a clear view over the host, with the system's edge interaction.
    private let reach = UIView()
    private var offsetWatch: NSKeyValueObservation?
    private weak var list: UIScrollView?
    /// [backdrop-ink] The page this host is on (found once).
    private weak var page: UIViewController?
    /// How far past the header the soft edge reaches once rows are under it (none at rest: the first row stays sharp).
    private static let reachBelow: CGFloat = 16
    /// A list this close to its top is at rest: it settles on a whole pixel, which an inset need not be.
    private static let restSlack: CGFloat = 0.5
    #if targetEnvironment(macCatalyst)
    private let backing = UIView()
    /// [backdrop] Theme › App Background: the backing is a copy of the picture, lined up with the page's.
    private let backingPicture = BackdropView(place: .app)
    private let fade = CAGradientLayer()
    /// How far below the bar the backing fades out, and how far the list scrolls before the backing is fully in.
    private static let fadeHeight: CGFloat = 16, rampDistance: CGFloat = 10
    #else
    /// [desktop-hard-edge] Owner 2026-11-15 on 1023: "You missed the background to the pills at the top." In the Desktop
    /// Look the system's hard edge ended at the bar's foot whatever its reach said, leaving Sessions' chips and Tasks'
    /// pills over sharp rows. In the look the band is ours, as the Mac chat's `barBlur`: a frost from the top down the
    /// whole header (the bar and the strip under it), cut off straight with a hairline, once rows are under it.
    private let desktopBand = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    /// [tinted-top-band] Owner 2026-11-22 (a recording of Sessions on a dark skin): the band came in as a neutral grey
    /// (#2B2D2F over a #13151B page), a block of another colour. It carries the look's bar veil over the frost, as the
    /// chat's band does (`DesktopFrost.barTintAlpha`), so it reads as the page frosted.
    private let desktopVeil = UIView()
    private var pageColour: UIColor = .clear
    private let desktopLine = UIView()
    /// [backdrop-ink] Owner 2026-11-15 (More scrolled on a night sky, Soft Cards): "I'm not happy with this… Look at top
    /// bar text color." Under the bar the soft edge blurs the pale cards and the dark picture between them into one
    /// middle grey, on which neither ink reads (the title 4.1:1, the gateway's line grey on grey). While the cards are
    /// under the bar it gets the cards' own tint (the page colour, as dense as this picture needs for label 2 at 4.5:1:
    /// `SoftCard.tint`), fading out under the header, so the bar's words stand on what the cards' words stand on.
    private let cardBand = UIView()
    private let cardFade = CAGradientLayer()
    private static let cardFadeHeight: CGFloat = 18
    #endif

    func watch(_ list: UIScrollView, page: UIColor) {
        self.list = list
        reach.isUserInteractionEnabled = false
        reach.backgroundColor = .clear
        reach.accessibilityIdentifier = "list.topEdge"
        superview?.insertSubview(reach, aboveSubview: self)
        let edge = UIScrollEdgeElementContainerInteraction()
        edge.scrollView = self
        edge.edge = .top
        reach.addInteraction(edge)
        #if targetEnvironment(macCatalyst)
        backing.backgroundColor = page
        backing.isUserInteractionEnabled = false
        backing.alpha = 0
        backing.accessibilityIdentifier = "list.barBacking"
        fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        backing.layer.mask = fade
        backingPicture.hidesInSheets = true
        backingPicture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backingPicture.frame = backing.bounds
        backing.addSubview(backingPicture)
        addSubview(backing)
        #else
        desktopBand.isUserInteractionEnabled = false
        desktopBand.isHidden = true
        desktopBand.accessibilityIdentifier = "list.desktopBand"
        desktopLine.isUserInteractionEnabled = false
        pageColour = page
        desktopVeil.isUserInteractionEnabled = false
        desktopVeil.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        desktopVeil.backgroundColor = DesktopFrost.tint(page, alpha: DesktopFrost.barTintAlpha)
        desktopBand.contentView.addSubview(desktopVeil)
        desktopBand.contentView.addSubview(desktopLine)
        superview?.insertSubview(desktopBand, aboveSubview: self)   // over the rows, under the strip and the bar
        cardBand.isUserInteractionEnabled = false
        cardBand.alpha = 0
        cardBand.accessibilityIdentifier = "list.cardBand"
        cardFade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        cardBand.layer.mask = cardFade
        superview?.insertSubview(cardBand, aboveSubview: self)
        registerForTraitChanges([ThemeGenerationTrait.self]) { (host: EdgeHostScrollView, _) in
            host.desktopVeil.backgroundColor = DesktopFrost.tint(host.pageColour, alpha: DesktopFrost.barTintAlpha)   // the new skin's page
            host.setNeedsLayout()
        }
        #endif
        offsetWatch = list.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateEdge() }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if contentSize != bounds.size { contentSize = bounds.size }
        #if targetEnvironment(macCatalyst)
        if backing.superview != nil { bringSubviewToFront(backing) }
        if backingPicture.alignedTo !== superview { backingPicture.alignedTo = superview }
        #endif
        updateEdge()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateEdge()
    }

    private func updateEdge() {
        guard let list else { return }
        let headerBottom = safeAreaInsets.top
        // [soft-cards] Owner 2026-11-13 (a recording of Tasks on build 975): "Check the glitch on the top bar." At
        // rest the bar wore the soft edge's band with a hard line under the pills, and both went the moment the list
        // was pulled. Soft Cards starts the list a fraction of a point lower (`BackdropCards.setTopRoom`: 1.7 pt on
        // Tasks), the list rests on a whole pixel (1.667), and that 0.03 pt read as rows under the bar. Under half a
        // point is rest.
        let past = list.contentOffset.y + list.adjustedContentInset.top
        let scrolledUnder = past < Self.restSlack ? min(past, 0) : past
        let below = min(max(scrolledUnder, 0), Self.reachBelow)
        let reachFrame = CGRect(x: frame.minX, y: frame.minY, width: bounds.width, height: headerBottom + below)
        if reach.frame != reachFrame { reach.frame = reachFrame }
        // Owner 2026-11-03: at rest the system's edge still fades out a band past the header, and it blurred Artifacts'
        // All / Images / Files / Links picker, the list's first row, right under the title. The host never scrolls, so
        // the system can't tell that nothing is under the bar yet: the edge shows once rows are, as a chat's does.
        #if targetEnvironment(macCatalyst)
        let hidden = scrolledUnder <= 0
        #else
        let desktop = Theme.isDesktop
        let hidden = scrolledUnder <= 0 || desktop   // [desktop-hard-edge] the look's band is `desktopBand`
        let bandFrame = CGRect(x: frame.minX, y: frame.minY, width: bounds.width, height: headerBottom)
        if desktopBand.frame != bandFrame {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            desktopBand.frame = bandFrame
            let line = HQShape.pixel(traitCollection.displayScale)
            desktopLine.frame = CGRect(x: 0, y: bandFrame.height - line, width: bandFrame.width, height: line)
            CATransaction.commit()
        }
        desktopLine.backgroundColor = HQPalette.separator
        // A fast swipe can put a row under the filters on the first frame. Fade only the hairline:
        // fading the frost and its page tint let the moving row's letters show through until they caught up.
        let hideBand = !desktop || scrolledUnder <= 0
        if desktopBand.isHidden != hideBand {
            desktopBand.isHidden = hideBand
            if !hideBand, window != nil { desktopLine.hqFadeIn(HQMotion.fade) }
        }
        #endif
        if topEdgeEffect.isHidden != hidden { topEdgeEffect.isHidden = hidden }
        // [backdrop-ink] On Soft Cards the rows under the bar are on cards of the page's colour: the bar's words keep
        // the mode's own ink while they are there (`BackdropBarInk.setCovered`).
        if page == nil { page = sequence(first: self as UIResponder, next: \.next).first { $0 is UIViewController } as? UIViewController }
        var covered = false
        if let page {
            let reach = BackdropBarInk.coveredPast(rest: headerBottom + BackdropCards.gap, in: self, page: page)
            covered = scrolledUnder > reach && BackdropCards.on(page)
            BackdropBarInk.setCovered(covered, on: page)
        }
        #if !targetEnvironment(macCatalyst)
        let cardFrame = CGRect(x: frame.minX, y: frame.minY, width: bounds.width, height: headerBottom + Self.cardFadeHeight)
        if cardBand.frame != cardFrame {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            cardBand.frame = cardFrame
            cardFade.frame = cardBand.bounds
            cardFade.locations = [0, NSNumber(value: Double(headerBottom / max(cardFrame.height, 1))), 1]
            CATransaction.commit()
        }
        if covered { cardBand.backgroundColor = SoftCard.tint(traitCollection) }
        let cardAlpha: CGFloat = covered ? 1 : 0
        if cardBand.alpha != cardAlpha {
            if window != nil, !HQMotion.reduced {
                UIView.animate(withDuration: HQMotion.quick, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { self.cardBand.alpha = cardAlpha }   // motion-ok: a fade, nothing moves
            } else {
                cardBand.alpha = cardAlpha
            }
        }
        #endif
        #if targetEnvironment(macCatalyst)
        guard backing.superview != nil else { return }
        // [Mac AAA 2026-11-17] With a strip of its own under the bar (Sessions' Bots | Projects row and pills, Tasks'
        // pills: the page's `additionalSafeAreaInsets.top`), the backing is solid 8 pt past the strip's foot before its
        // fade, as under the chat's title stack: rows scrolled up stood half cut against the switch row ("App 2 ›"
        // sliced under the pills, a face's top half), the owner's kind of photo.
        let strip = (page?.additionalSafeAreaInsets.top ?? 0) > 0.5
        let solid = headerBottom + (strip ? ChatMetrics.macFloatGap : 0)
        let height = solid + Self.fadeHeight
        let frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        if backing.frame != frame {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            backing.frame = frame
            fade.frame = backing.bounds
            fade.locations = [0, NSNumber(value: Double(solid / max(height, 1))), 1]
            CATransaction.commit()
        }
        // [mac-audit] Owner 2026-11-02 (#22): in the Desktop Look too. Its frosted bar (`ListBarAppearance.apply`) has no
        // rule and no soft edge, so More's gateway card was cut straight across at the bar's edge as it scrolled under
        // ("127.0.0.1:9881" sliced in half under MORE); with the backing rows fade out over 16 pt before the bar.
        let alpha = min(max(scrolledUnder / Self.rampDistance, 0), 1)
        if backing.alpha != alpha { backing.alpha = alpha }
        #endif
    }
}

// [desktoplook] Computed, and each one notes the live theme: a SwiftUI body that reads a colour runs again when the
// theme changes. One Color per token per theme generation: equal while the theme stays the same (so SwiftUI sees no
// change on an ordinary body run), different after a change (so it redraws).
extension Color {
    private static var themedGeneration = -1
    private static var themedCache: [PartialKeyPath<ThemeTokens>: Color] = [:]

    private static func themed(_ token: KeyPath<ThemeTokens, RGBA> & Sendable) -> Color {
        Theme.touch()
        let generation = Theme.shared.generation
        if generation != themedGeneration {
            themedGeneration = generation
            themedCache.removeAll(keepingCapacity: true)
        }
        if let cached = themedCache[token] { return cached }
        let made = Color(uiColor: ThemedColor.make(token))
        themedCache[token] = made
        return made
    }
    static var hqPage: Color { themed(\.page) }
    static var hqLabel: Color { themed(\.label) }
    static var hqLabel2: Color { themed(\.label2) }
    static var hqLabel3: Color { themed(\.label3) }
    static var hqTint: Color { themed(\.tint) }
    static var hqTintText: Color { themed(\.tintText) }
    static var hqFill3: Color { themed(\.fill3) }
    static var hqOrange: Color { themed(\.orange) }
    static var hqRed: Color { themed(\.red) }
    /// Ready, Connected: iOS's green in the shade that reads as small text on the page (the stock green is 2:1 on white).
    static var hqGreen: Color { themed(\.green) }
    static var hqMuted: Color { themed(\.muted) }
    static var hqGroupedCard: Color { themed(\.groupedCard) }
    static var hqStroke: Color { themed(\.strokeSecondary) }
    static var hqOnTint: Color { themed(\.onTint) }
    /// The chat's bubbles (Theme › Bubble Corners previews them).
    static var hqMeBubble: Color { themed(\.meBubble) }
    static var hqMeText: Color { themed(\.meText) }
    static var hqBotBubble: Color { themed(\.botBubble) }
    /// The page behind grouped content drawn by hand (not a List: those use `.hqGroupedPage()`).
    static var hqGroupedPage: Color {
        Theme.touch()
        let generation = Theme.shared.generation
        if generation != groupedGeneration { groupedGeneration = generation; groupedColor = Color(uiColor: HQPalette.groupedPage) }
        return groupedColor
    }
    private static var groupedGeneration = -1
    private static var groupedColor = Color.clear
}

// [desktoplook] A List or Form's page follows the picked skin. Nothing is changed in the standard look or the iOS
// System skin (the list keeps the system's own background, at the system's own level); with another skin the system
// background is hidden and the skin's grouped colour is drawn. Rows keep iOS's cards, so they keep its press highlight
// (the web keeps iOS's cells under a skin too: phone-ios-tokens.css:113).
private struct GroupedPageModifier: ViewModifier {
    @Environment(\.hqGlassSheet) private var glassSheet
    @Environment(\.hqChatLead) private var chatLead
    @Environment(\.colorScheme) private var scheme
    #if targetEnvironment(macCatalyst)
    @Environment(\.macFormLeastSide) private var formSide
    #endif

    @ViewBuilder func body(content: Content) -> some View {
        let _ = Theme.touch()
        // [mac-audit] Owner 2026-11-02 #8: the Mac in dark paints its page too (`ThemedColor.macDarkGrouped`): iOS's
        // own grouped page there is a neutral grey beside the look's navy.
        let system = !ThemedColor.paintsGroupedPage(UITraitCollection { traits in
            traits.userInterfaceStyle = scheme == .dark ? .dark : .light
            traits[ThemeGenerationTrait.self] = ThemeTable.generation
        })
        // [desktoplook2] The look: flat outlined sections (App/Theme/DesktopLists.swift), the 20 pt gutter, switches
        // and controls in the accent. Look off: exactly the lines below the `if`.
        if Theme.isDesktop {
            content
                .scrollContentBackground(.hidden)
                .background(chatLead ? Color.clear : Color.hqGroupedPage)   // [tasks] on a chat: the chat's page
                .background(DesktopListProbe())
                .listSectionSpacing(18)
                .tint(Color.hqTintText)
        } else if chatLead {
            // [tasks] On a chat's page: no page of its own (the chat's colour or picture shows), cards as the chat's.
            content
                .scrollContentBackground(.hidden)
                .listSectionSpacing(.compact)
                .tint(Self.inkTint)
                .hqInkSwitches()   // [paper-ink]
        } else if glassSheet {
            // [glass] In a sheet on Liquid Glass: no page, so the glass shows around the rows (each Section keeps its
            // rows' cards solid with `hqSheetRows`). [glass-design] Each section's cards get their thin edge.
            content
                .scrollContentBackground(.hidden)
                .background(GlassListProbe())
                .listSectionSpacing(.compact)
                .tint(Self.inkTint)
                .hqInkSwitches()   // [paper-ink]
        } else {
            // [compact] iOS's compact gap between sections (owner 2026-10-17: things too tall); a header still
            // draws above its section.
            // [backdrop] Theme › App Background: the picture behind the page (its layer keeps the grouped colour in a sheet).
            let backdrop = Backdrop.app.shows
            // [macpass-chat] A form page in a Mac sheet (Settings' model chooser) paints the sheet's page itself: the
            // system's own background there left white bands across the sheet in light, in the gaps between sections
            // without a header or footer (around Search Models, under the Model card). Bot Info's pages had none.
            #if targetEnvironment(macCatalyst)
            let sheetForm = formSide == MacForm.sheetSide
            #else
            let sheetForm = false
            #endif
            content
                .scrollContentBackground(system && !backdrop && !sheetForm ? .automatic : .hidden)
                .background {
                    // 2026-11-02 theme audit: the skin's page runs up under the bar too; a `.background { }` view
                    // stops at the safe area, which left iOS's black (or white) strip behind the clock and title.
                    if backdrop { PageBackdropLayer().ignoresSafeArea() }
                    else if !system { Color.hqGroupedPage.ignoresSafeArea() }
                    else if sheetForm { Color(uiColor: HQPalette.sheetPage).ignoresSafeArea() }
                }
                .hqMacCardCorners()   // [mac-ui-issues] a Mac group box's corners, not iOS's card ends
                // [backdrop-cards] On Soft Cards a little more room between sections, so each plate keeps its own.
                .listSectionSpacing(backdrop && Backdrop.app.cards ? .custom(BackdropPlates.sectionSpacing) : .compact)
                .tint(Self.inkTint)
                .hqInkSwitches()   // [paper-ink]
        }
    }

    /// [paper-icons] A skin with ink icons draws its switches and controls in its ink too, not iOS's green; every other
    /// skin keeps what it had (nil: inherited).
    private static var inkTint: Color? { Theme.inkIcons != nil ? Color.hqTintText : nil }
}

extension View {
    /// [paper-ink] Switches in an ink skin: `Theme.inkSwitch` (other controls keep the ink). Elsewhere unchanged.
    @ViewBuilder func hqInkSwitches() -> some View {
        if let ink = Theme.inkSwitch { self.toggleStyle(SwitchToggleStyle(tint: Color(uiColor: ink))) } else { self }
    }
}

/// [glass] A Section's rows on a glass sheet: solid cards (iOS draws them see-through on glass, and what is behind the
/// sheet then tints the values; `HQPalette.sheetCard`). Anywhere else the rows are left as they are.
private struct SheetRowsModifier: ViewModifier {
    @Environment(\.hqGlassSheet) private var glassSheet
    @Environment(\.hqChatLead) private var chatLead

    @ViewBuilder func body(content: Content) -> some View {
        if chatLead && !Theme.isDesktop {
            content.listRowBackground(Color(uiColor: TaskPanel.card))   // [tasks] cards on the task's panel
        } else if glassSheet && !Theme.isDesktop {
            content.listRowBackground(Color(uiColor: HQPalette.sheetCard))
        } else {
            content
        }
    }
}

extension View {
    /// [glass] Put on each Section of a grouped List that can show in a glass sheet.
    func hqSheetRows() -> some View { modifier(SheetRowsModifier()) }

    /// Put on every grouped `List` / `Form` (scripts/desktoplook-migrate.py adds it and checks none is missing).
    func hqGroupedPage() -> some View { modifier(GroupedPageModifier()) }

    /// A menu picker in a grouped row: its value and chevrons in the secondary grey, as Bot Info's Mute Notifications
    /// and the task sheet's rows draw theirs (UX study 2026-10-19 #102: some menu rows were blue, some grey).
    func hqMenuPicker() -> some View { pickerStyle(.menu).tint(Color.hqLabel2) }
}
