// [glass-design] What sits on a pop-up's Liquid Glass (owner 2026-10-30: "we need to design all of the stuff that is on
// top of the Liquid Glass better - like all of the stuff on the pop ups"). One set of pieces every half-height sheet uses,
// so a new pop-up gets them by using them, not by a fix of its own:
//
// 1. Words people read sit on a card (`HQPalette.sheetCard`): a frosted pane on the glass, never a solid grey slab (owner
//    2026-11-01: "I just don't like the hard colors (grey background) on the Liquid Glass pop up"); a code block on it is
//    a shade (`HQPalette.sheetCode`). What stays on the glass itself is a title, a one-line
//    section label, or an empty state, in ink that passes 4.5:1 over the worst backdrop: never label 3, and an empty
//    state's line in the primary label (`HQPalette.glassInk2`; label 2 measured 3.2:1 over the blurred chat).
// 2. No glass on glass: an action on the page (Copy, Try Again, New Prompt, Show Details, a red decline) is
//    `hqSheetAction`, a card-coloured capsule with the tint's words in semibold, 44 pt tall, the same in UIKit and
//    SwiftUI. On anything opaque (a card, the page at full height) the capsule is the tint at 12 % instead, so it
//    still stands out. The one prominent verb (Done, Save, Send, `hqSheetProminent`) keeps the accent.
// 3. A search field on the page is a card like the others (`UISearchBar.hqSolidOnGlass`).
// 4. One empty state for every sheet (`PageStates.sheetState` in UIKit, `SheetEmptyState` in SwiftUI): the same symbol,
//    title, line and button, measured the same.
// 5. A card on the glass has a thin edge (`HQPalette.glassEdge`: white 12 % in dark, black 6 % in light; owner
//    2026-11-01): the dark card measured 1.05:1 against the dark glass. A grouped list gets one edge round each section
//    (`GlassCardOutliner`), a hand-made card `hqGlassEdge()`, an action's capsule its own. Off the glass, none.
//
// Off the glass the pieces keep what each place drew before, except where it is better there too (the same empty state
// and button at full height and on the iPad). The Desktop Look and the Mac keep their own pieces exactly: the look has
// no glass, and the Mac's sheets are solid with its push buttons.

import SwiftUI
import UIKit

enum GlassSheetKit {
    /// A sheet card's corners: iOS 26's inset-grouped card (measured 26 pt on Choose a Bot), so a hand-made card
    /// (How Voice Works, a prompt's explanation) has the corners of the rows beside it.
    static let cardRadius: CGFloat = 26
    /// Words inside a hand-made card, from its edge (the grouped rows' 16 pt).
    static let cardPadding: CGFloat = 16
    /// An action's least height (a touch target), and its words' inset.
    static let actionHeight: CGFloat = 44
    static let actionInsets = NSDirectionalEdgeInsets(top: 11, leading: 20, bottom: 11, trailing: 20)
    /// The empty state's measures (UIKit and SwiftUI alike).
    static let emptySymbolSize: CGFloat = 40
    static let emptySymbolGap: CGFloat = 12, emptyLineGap: CGFloat = 6, emptyButtonGap: CGFloat = 20, emptyButtonsGap: CGFloat = 10
    static let emptySide: CGFloat = 32

    /// The pieces of rule 1–4 are drawn: the iOS look off the Mac (the Desktop Look and the Mac keep their own).
    @MainActor static var designed: Bool { !Theme.isDesktop && !DeviceWord.isMac }

    /// An action's words: Body semibold (17 pt and bold, so the tint and the red read at 3:1 as large text does).
    @MainActor static var actionFont: UIFont { HQFont.preferred(.body).pagesWeight(.semibold) }
}

// MARK: - Actions (rule 2)

extension UIButton.Configuration {
    /// [glass-design] An action on a sheet's page: a card-coloured capsule with the tint's words (`destructive`: the red),
    /// 44 pt tall, never glass on the glass. The Mac keeps its push button; the Desktop Look its outlined button (a red
    /// decline stays a plain red word there, as it was).
    /// `onCard`: the action stands on a solid card (Screen Control's Check Setup), so it is never card-coloured.
    @MainActor static func hqSheetAction(destructive: Bool = false, onCard: Bool = false) -> UIButton.Configuration {
        if DeviceWord.isMac { return MacPush.configuration(destructive ? .destructive : .plain) }
        if Theme.isDesktop {
            guard destructive else { return hqGlass() }
            var config = UIButton.Configuration.plain()
            config.baseForegroundColor = ChatPalette.red
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
                var a = a; a.font = HQFont.preferred(.body); return a
            }
            return config
        }
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = HQPalette.sheetActionFill(destructive: destructive, onCard: onCard)
        // Rule 5: on the glass the capsule has the cards' thin edge (nothing on a card or an opaque page).
        if !onCard { config.background.strokeColor = HQPalette.glassEdge; config.background.strokeWidth = 1 }
        config.baseForegroundColor = destructive ? HQPalette.red : HQPalette.tintText
        config.cornerStyle = .capsule
        config.contentInsets = GlassSheetKit.actionInsets
        config.imagePadding = 6
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body, scale: .medium)
        config.titleLineBreakMode = .byWordWrapping
        let font = GlassSheetKit.actionFont
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a; a.font = font; return a
        }
        return config
    }
}

extension UIButton.Configuration {
    /// [glass-design] The one prominent verb among sheet actions (Screen Control's Enable Control with Hermes): the
    /// accent capsule with its own words, the same size as `hqSheetAction`. The Mac's prominent push button, and the
    /// Desktop Look's prominent glass, as before.
    @MainActor static func hqSheetProminent() -> UIButton.Configuration {
        if DeviceWord.isMac { return MacPush.configuration(.prominent) }
        if Theme.isDesktop { return hqProminentGlass() }
        var config = hqSheetAction()
        config.baseBackgroundColor = HQPalette.tint
        config.baseForegroundColor = HQPalette.onTint
        config.background.strokeColor = nil
        return config
    }
}

/// [glass-design] `hqSheetAction` in SwiftUI: the same capsule, words and height.
struct SheetActionButtonStyle: ButtonStyle {
    var destructive = false
    var onCard = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.hqGlassSheet) private var glass

    /// `HQPalette.sheetActionFill`: the card on the glass, the tint at 12 % on anything opaque.
    private var fill: Color {
        if glass && !onCard { return Color(uiColor: HQPalette.sheetCard) }
        return (destructive ? Color.hqRed : Color.hqTint).opacity(0.12)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Font.hq(.body).weight(.semibold))
            .foregroundStyle(destructive ? Color.hqRed : Color.hqTintText)
            .multilineTextAlignment(.center)
            .padding(.horizontal, GlassSheetKit.actionInsets.leading)
            .padding(.vertical, GlassSheetKit.actionInsets.top)
            .frame(minHeight: GlassSheetKit.actionHeight)
            .background(Capsule().fill(fill))
            .overlay { if glass && !onCard { Capsule().strokeBorder(Color(uiColor: HQPalette.cardEdge), lineWidth: 1) } }
            .opacity(configuration.isPressed ? 0.6 : enabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

extension View {
    /// [glass-design] An action on a sheet's page (New Prompt): `SheetActionButtonStyle`; the Mac's push button and the
    /// Desktop Look's outlined button, as `hqBorderedButtonStyle` drew them.
    @ViewBuilder func hqSheetActionButtonStyle() -> some View {
        if DeviceWord.isMac { self.buttonStyle(MacPushButtonStyle()) }
        else if Theme.isDesktop { self.buttonStyle(DesktopOutlinedButtonStyle()) }
        else { self.buttonStyle(SheetActionButtonStyle()) }
    }
}

// MARK: - Empty states (rules 1 and 4)

extension PageStates {
    /// [glass-design] A sheet's empty or failed state: symbol, title, a line, and its actions (`hqSheetAction`), in the
    /// measures `SheetEmptyState` uses. On the glass the line is the primary label (`HQPalette.glassInk2`). The Desktop
    /// Look and the Mac get the state they had: `PageStates.empty` with the look's push or outlined buttons.
    @MainActor static func sheetState(symbol: String?, title: String, text: String?, desktopTitleFont: UIFont? = nil,
                                      actions: [UIAction] = []) -> UIContentUnavailableConfiguration {
        var config: UIContentUnavailableConfiguration
        if GlassSheetKit.designed {
            config = UIContentUnavailableConfiguration.empty()
            config.image = symbol.flatMap { UIImage(systemName: $0) }
            let symbolFont = UIFontMetrics(forTextStyle: .title1).scaledFont(for: HQFont.system(ofSize: GlassSheetKit.emptySymbolSize))
            config.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: symbolFont)
            config.imageProperties.tintColor = HQPalette.label2
            config.text = title
            config.textProperties.font = HQFont.preferred(.title3).pagesWeight(.bold)
            config.textProperties.color = HQPalette.label
            config.secondaryText = text
            config.secondaryTextProperties.font = HQFont.preferred(.subheadline)
            config.secondaryTextProperties.color = HQPalette.glassInk2
            config.imageToTextPadding = GlassSheetKit.emptySymbolGap
            config.textToSecondaryTextPadding = GlassSheetKit.emptyLineGap
            config.textToButtonPadding = GlassSheetKit.emptyButtonGap
            config.buttonToSecondaryButtonPadding = GlassSheetKit.emptyButtonsGap
            config.directionalLayoutMargins.leading = GlassSheetKit.emptySide
            config.directionalLayoutMargins.trailing = GlassSheetKit.emptySide
        } else {
            config = UIContentUnavailableConfiguration.empty().hqScaled()
            config.image = symbol.flatMap { UIImage(systemName: $0) }
            config.text = title
            config.secondaryText = text
            if let desktopTitleFont, !DeviceWord.isMac { config.textProperties.font = desktopTitleFont }
        }
        for (index, action) in actions.prefix(2).enumerated() {
            var button = UIButton.Configuration.hqSheetAction()
            // Off the designed look the second action stays the plain word it was (Show Details).
            if index == 1, !GlassSheetKit.designed { button = .plain() }
            button.title = action.title
            if index == 0 {
                config.button = button
                config.buttonProperties.primaryAction = action
            } else {
                config.secondaryButton = button
                config.secondaryButtonProperties.primaryAction = action
            }
        }
        return config
    }
}

/// [glass-design] `PageStates.sheetState` in SwiftUI (Prompts' "No Prompts Yet"): the same symbol, title, line, gaps and
/// button. Only for the designed look (`GlassSheetKit.designed`); the Desktop Look and the Mac draw their own.
struct SheetEmptyState<Actions: View>: View {
    var symbol: String
    var title: String
    var text: String
    @ViewBuilder var actions: () -> Actions
    @Environment(\.hqGlassSheet) private var glass
    @ScaledMetric(relativeTo: .title) private var symbolSize = GlassSheetKit.emptySymbolSize

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(Font.hqSystem(size: symbolSize))
                .foregroundStyle(Color.hqLabel2)
                .accessibilityHidden(true)
            Text(title)
                .font(Font.hq(.title3).bold())
                .foregroundStyle(Color.hqLabel)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, GlassSheetKit.emptySymbolGap)
            Text(text)
                .font(Font.hq(.subheadline))
                .foregroundStyle(glass ? Color.hqLabel : Color.hqLabel2)
                .padding(.top, GlassSheetKit.emptyLineGap)
            VStack(spacing: GlassSheetKit.emptyButtonsGap) { actions() }
                .padding(.top, GlassSheetKit.emptyButtonGap)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, GlassSheetKit.emptySide)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Search fields (rule 3)

extension UISearchBar {
    /// [glass-design] A sheet's search field: solid like the cards while the sheet sits on glass (iOS drew it see-through,
    /// its placeholder 4.0:1 over the chat), its placeholder in label 2, and its capsule exactly as wide as the cards
    /// under it (iOS draws the field 4 pt outside them at each end); off the glass, the system's field as before.
    func hqSolidOnGlass() {
        applyGlassField()
        registerForTraitChanges([GlassSheetTrait.self, UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (bar: UISearchBar, _) in
            bar.applyGlassField()
        }
    }

    private func applyGlassField() {
        let glass = traitCollection[GlassSheetTrait.self] && GlassSheetKit.designed
        let field = searchTextField
        let capsule = field.subviews.first { $0 is SearchFieldCapsule }
        if glass {
            // The field keeps its frame (the bar lays it out); the solid capsule is drawn inside it, inset to the
            // cards' edges, and the glyphs and words move in with it.
            field.borderStyle = .none
            field.backgroundColor = .clear
            if capsule == nil {
                let made = SearchFieldCapsule()
                made.translatesAutoresizingMaskIntoConstraints = false
                made.isUserInteractionEnabled = false
                field.insertSubview(made, at: 0)
                NSLayoutConstraint.activate([
                    made.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: SearchFieldCapsule.inset),
                    made.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -SearchFieldCapsule.inset),
                    made.topAnchor.constraint(equalTo: field.topAnchor),
                    made.bottomAnchor.constraint(equalTo: field.bottomAnchor),
                ])
            }
            setPositionAdjustment(UIOffset(horizontal: SearchFieldCapsule.inset + 4, vertical: 0), for: .search)
            setPositionAdjustment(UIOffset(horizontal: -SearchFieldCapsule.inset, vertical: 0), for: .clear)
            searchTextPositionAdjustment = UIOffset(horizontal: SearchFieldCapsule.inset, vertical: 0)
            if let words = placeholder {
                field.attributedPlaceholder = NSAttributedString(string: words, attributes: [.foregroundColor: HQPalette.label2])
            }
        } else if let capsule {
            capsule.removeFromSuperview()
            field.borderStyle = .roundedRect
            field.backgroundColor = nil
            setPositionAdjustment(.zero, for: .search)
            setPositionAdjustment(.zero, for: .clear)
            searchTextPositionAdjustment = .zero
            if let words = placeholder { field.attributedPlaceholder = nil; placeholder = words }
        }
    }
}

/// [glass-design] The solid capsule a sheet's search field draws on the glass: the card colour, rounded to its height,
/// kept `inset` in from the field's ends as the field resizes.
final class SearchFieldCapsule: UIView {
    static let inset: CGFloat = 4

    init() {
        super.init(frame: .zero)
        backgroundColor = HQPalette.sheetCard
        layer.cornerCurve = .continuous
        hqGlassEdge()   // rule 5: the cards' thin edge
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}

// MARK: - A card that is only there on glass (rule 1)

/// [glass-design] Holds lines people read (How Voice Works' rows, a prompt's explanation): on the glass a frosted card with
/// the rows' corners and padding; off it nothing at all, so the words sit where they always did. `onGlassChange` lets
/// the page move the card's edges (it is told at once, and after every change).
final class SheetGlassCard: UIView {
    let content = UIStackView()
    var onGlassChange: ((Bool) -> Void)? { didSet { onGlassChange?(glass) } }
    private(set) var glass = false
    private var edges: [NSLayoutConstraint] = []

    init(axis: NSLayoutConstraint.Axis = .vertical, spacing: CGFloat = 0) {
        super.init(frame: .zero)
        backgroundColor = HQPalette.glassCard
        layer.cornerRadius = GlassSheetKit.cardRadius
        layer.cornerCurve = .continuous
        hqGlassEdge()   // rule 5: the cards' thin edge
        content.axis = axis
        content.spacing = spacing
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        edges = [
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ]
        NSLayoutConstraint.activate(edges)
        follow()
        registerForTraitChanges([GlassSheetTrait.self]) { (card: SheetGlassCard, _) in card.follow() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Vertical padding on the glass: a little less than the sides, as a grouped card's rows bring their own.
    var verticalPadding: CGFloat = GlassSheetKit.cardPadding { didSet { follow() } }

    private func follow() {
        glass = traitCollection[GlassSheetTrait.self] && GlassSheetKit.designed
        let side = glass ? GlassSheetKit.cardPadding : 0, vertical = glass ? verticalPadding : 0
        edges[0].constant = vertical; edges[3].constant = vertical
        edges[1].constant = side; edges[2].constant = side
        onGlassChange?(glass)
    }
}

// MARK: - The trait for a sheet that keeps its own page

extension UISheetPresentationController {
    /// [glass-design] A sheet that keeps the page and background it has (How Voice Works: the system's glass, its own
    /// colour effect in the Desktop Look) but wants to know when it sits on glass (`GlassSheetTrait`), so its words can
    /// go on a card there.
    func hqGlassTrait() {
        SheetGlass.install()
        SheetGlass.markTraitOnly(self)
        SheetGlass.layout(self)
    }
}

// MARK: - Card edges (rule 5)

private enum GlassEdges {
    static let key = malloc(1)!
    static let alwaysKey = malloc(1)!
    static let cardKey = malloc(1)!
}

extension UIView {
    /// [glass-design] A hand-made card's thin edge (`HQPalette.glassEdge`) while its sheet sits on glass, none off it.
    /// `always`: the card stands on glass wherever it shows (the model panel's own glass), so the edge is always drawn
    /// (`HQPalette.cardEdge`). Follows the appearance and the sheet's height.
    func hqGlassEdge(always: Bool = false) {
        objc_setAssociatedObject(self, GlassEdges.alwaysKey, always, .OBJC_ASSOCIATION_RETAIN)
        paintGlassEdge()
        guard objc_getAssociatedObject(self, GlassEdges.key) == nil else { return }
        objc_setAssociatedObject(self, GlassEdges.key, true, .OBJC_ASSOCIATION_RETAIN)
        registerForTraitChanges([GlassSheetTrait.self, UITraitUserInterfaceStyle.self]) { (view: UIView, _) in view.paintGlassEdge() }
    }

    private func paintGlassEdge() {
        let always = objc_getAssociatedObject(self, GlassEdges.alwaysKey) as? Bool ?? false
        let edge = (always ? HQPalette.cardEdge : HQPalette.glassEdge).resolvedColor(with: traitCollection).cgColor
        layer.borderWidth = edge.alpha > 0 ? 1 : 0
        layer.borderColor = edge.alpha > 0 ? edge : nil
    }
}

extension UITableViewCell {
    /// Set by `hqSolidOnGlass()`: the row draws a card, so its section gets an edge (`GlassCardOutliner`).
    fileprivate(set) var hqGlassCard: Bool {
        get { objc_getAssociatedObject(self, GlassEdges.cardKey) != nil }
        set { objc_setAssociatedObject(self, GlassEdges.cardKey, newValue ? true : nil, .OBJC_ASSOCIATION_RETAIN) }
    }

    /// [glass-design] Marks the row as a card and outlines its section while the sheet sits on glass.
    func hqEdgeOnGlass() {
        hqGlassCard = true
        var up = superview
        while let view = up, !(view is UITableView) { up = view.superview }
        if let table = up as? UITableView { GlassCardOutliner.attach(to: table) }
    }
}

/// [glass-design] Rule 5 for grouped lists: one thin edge round each section's rows while the sheet sits on glass (an
/// edge on every row would also draw a line between the rows). Laid over the list as the Desktop Look's outline is
/// (App/Theme/DesktopLists.swift), following the rows' frames as it scrolls, with the cards' own corners. A section
/// whose rows draw no card (an empty state, a button standing on the glass) gets none. UIKit tables attach it from
/// `hqSolidOnGlass()`, SwiftUI lists from `hqGroupedPage()` on a glass sheet; off the glass it draws nothing.
@MainActor final class GlassCardOutliner: NSObject {
    private weak var list: UIScrollView?
    private let stroke = CAShapeLayer()
    private var watches: [NSKeyValueObservation] = []
    private var scheduled = false
    /// The cards' corners, read from a section's first or last row as it shows (the table's and SwiftUI's differ).
    private var radius = GlassSheetKit.cardRadius
    private static let key = malloc(1)!

    private init(list: UIScrollView) {
        self.list = list
        super.init()
        stroke.name = "hq.glass.edge"
        stroke.fillColor = nil
        stroke.lineWidth = 1
        stroke.zPosition = 50
        stroke.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(), "strokeColor": NSNull()]
        list.layer.addSublayer(stroke)
        watches = [
            list.observe(\.contentSize, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.schedule() } },
            list.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.update() } },
            list.observe(\.bounds, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.schedule() } },
        ]
        list.registerForTraitChanges([GlassSheetTrait.self, UITraitUserInterfaceStyle.self]) { [weak self] (_: UIScrollView, _) in
            self?.schedule()
        }
    }

    /// Attaches (once) to a table or a SwiftUI list on a glass sheet; again later only redraws.
    static func attach(to list: UIScrollView) {
        guard list is UITableView || list is UICollectionView else { return }
        if let existing = objc_getAssociatedObject(list, key) as? GlassCardOutliner { existing.schedule(); return }
        guard list.traitCollection[GlassSheetTrait.self], GlassSheetKit.designed else { return }
        let outliner = GlassCardOutliner(list: list)
        objc_setAssociatedObject(list, key, outliner, .OBJC_ASSOCIATION_RETAIN)
        outliner.schedule()
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduled = false
                self?.update()
            }
        }
    }

    private func update() {
        guard let list else { return }
        guard list.traitCollection[GlassSheetTrait.self], GlassSheetKit.designed else {
            if stroke.path != nil { stroke.path = nil }
            return
        }
        let visible = list.bounds.insetBy(dx: 0, dy: -400)
        let path = UIBezierPath()
        for section in sections(of: list) where section.card && section.box.intersects(visible) && section.box.height > 1 {
            path.append(UIBezierPath(roundedRect: section.box.insetBy(dx: 0.5, dy: 0.5), cornerRadius: max(0, radius - 0.5)))
        }
        stroke.frame = CGRect(origin: .zero, size: list.contentSize)
        stroke.path = path.cgPath
        stroke.strokeColor = HQPalette.cardEdge.resolvedColor(with: list.traitCollection).cgColor
    }

    /// Each section's rows as one box, and whether a row in it that shows draws a card (one that doesn't show is
    /// off-screen with its box). Reads the cards' corners as it goes.
    private func sections(of list: UIScrollView) -> [(box: CGRect, card: Bool)] {
        var cardSections = Set<Int>()
        var found: [(box: CGRect, card: Bool)] = []
        if let table = list as? UITableView {
            for cell in table.visibleCells where cell.hqGlassCard {
                guard let path = table.indexPath(for: cell) else { continue }
                cardSections.insert(path.section)
                measure(cell)
            }
            for section in 0..<table.numberOfSections {
                let count = table.numberOfRows(inSection: section)
                guard count > 0 else { continue }
                let box = table.rectForRow(at: IndexPath(row: 0, section: section))
                    .union(table.rectForRow(at: IndexPath(row: count - 1, section: section)))
                found.append((box, cardSections.contains(section)))
            }
        } else if let grid = list as? UICollectionView {
            for path in grid.indexPathsForVisibleItems {
                guard let cell = grid.cellForItem(at: path), Self.drawsCard(cell) else { continue }
                cardSections.insert(path.section)
                measure(cell)
            }
            let layout = grid.collectionViewLayout
            for section in 0..<grid.numberOfSections {
                let count = grid.numberOfItems(inSection: section)
                guard count > 0, let first = layout.layoutAttributesForItem(at: IndexPath(item: 0, section: section)),
                      let last = layout.layoutAttributesForItem(at: IndexPath(item: count - 1, section: section)) else { continue }
                found.append((first.frame.union(last.frame), cardSections.contains(section)))
            }
        }
        return found
    }

    /// A SwiftUI row draws a card unless it was drawn clear on purpose (`listRowBackground(Color.clear)`, or marked bare).
    private static func drawsCard(_ cell: UICollectionViewCell) -> Bool {
        if let row = cell as? UICollectionViewListCell, row.hqBareRow { return false }
        guard let background = cell.backgroundConfiguration else { return true }
        // 2026-11-02 (New Job, owner: "pretty big UI issue"): SwiftUI hands `listRowBackground(Color.clear)` over as a
        // custom view that draws nothing, so the Bot, Start From and Schedule strips each got an edge round the whole
        // sheet's width, cut off at its sides. A custom view counts only if something in it draws.
        if let custom = background.customView { return draws(custom.layer, in: cell.traitCollection) }
        guard let fill = background.backgroundColor else { return true }
        return fill.resolvedColor(with: cell.traitCollection).cgColor.alpha > 0.01
    }

    /// Whether a layer or one below it paints anything: a fill, an edge, contents or a shape.
    private static func draws(_ layer: CALayer, in traits: UITraitCollection, depth: Int = 0) -> Bool {
        if layer.isHidden || layer.opacity < 0.01 { return false }
        if let fill = layer.backgroundColor, fill.alpha > 0.01 { return true }
        if layer.borderWidth > 0 || layer.contents != nil { return true }
        if let shape = layer as? CAShapeLayer, shape.path != nil { return true }
        guard depth < 6 else { return true }
        return layer.sublayers?.contains { draws($0, in: traits, depth: depth + 1) } ?? false
    }

    private func measure(_ cell: UIView) {
        #if !targetEnvironment(macCatalyst)
        let corner = max(cell.effectiveRadius(corner: .topLeft), cell.effectiveRadius(corner: .bottomLeft))
        if corner > 1 { radius = corner }
        #endif
    }
}

/// [glass-design] Put behind a SwiftUI List / Form on a glass sheet (`hqGroupedPage`): finds the list beside it and
/// attaches `GlassCardOutliner`, as `DesktopListProbe` does for the Desktop Look's outline.
struct GlassListProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView { ProbeView() }
    func updateUIView(_ view: ProbeView, context: Context) { view.find() }

    final class ProbeView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            find()
        }

        func find() {
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.window != nil else { return }
                    var ancestor = self.superview
                    for _ in 0..<6 {
                        guard let current = ancestor else { return }
                        if let list = Self.firstList(in: current, depth: 6) {
                            GlassCardOutliner.attach(to: list)
                            return
                        }
                        ancestor = current.superview
                    }
                }
            }
        }

        private static func firstList(in view: UIView, depth: Int) -> UICollectionView? {
            if let list = view as? UICollectionView { return list }
            guard depth > 0 else { return nil }
            for child in view.subviews { if let found = firstList(in: child, depth: depth - 1) { return found } }
            return nil
        }
    }
}

// MARK: - SwiftUI sheets (rule 0)

extension View {
    /// [glass-audit] A SwiftUI `.sheet` on Liquid Glass, as `hqGlassPage()` puts a UIKit one: its sheet's controller is
    /// found from inside and marked, so the page goes clear at half height, `hqGroupedPage` / `hqSheetRows` /
    /// `hqGlassCard` turn their cards frosted, and the Desktop Look gets its opaque page. Put it on the sheet's root view.
    func hqGlassSheetPage() -> some View { background(GlassSheetPageProbe().frame(width: 0, height: 0).accessibilityHidden(true)) }

    /// [glass-audit] Lines people read on a sheet (a Star Map star's facts): on the glass a frosted card with the rows'
    /// corners, padding and thin edge (`SheetGlassCard` in SwiftUI); off it nothing, so the words sit where they always did.
    func hqGlassCard() -> some View { modifier(GlassCardModifier()) }
}

private struct GlassCardModifier: ViewModifier {
    @Environment(\.hqGlassSheet) private var glass

    @ViewBuilder func body(content: Content) -> some View {
        if glass && GlassSheetKit.designed {
            content
                .padding(.horizontal, GlassSheetKit.cardPadding)
                .padding(.vertical, GlassSheetKit.cardPadding - 4)
                .background(RoundedRectangle(cornerRadius: GlassSheetKit.cardRadius, style: .continuous)
                    .fill(Color(uiColor: HQPalette.sheetCard)))
                .overlay(RoundedRectangle(cornerRadius: GlassSheetKit.cardRadius, style: .continuous)
                    .strokeBorder(Color(uiColor: HQPalette.glassEdge), lineWidth: 1))   // rule 5
        } else {
            content
        }
    }
}

private struct GlassSheetPageProbe: UIViewControllerRepresentable {
    final class Probe: UIViewController {
        override func viewIsAppearing(_ animated: Bool) {
            super.viewIsAppearing(animated)
            var top: UIViewController = self
            while let parent = top.parent { top = parent }
            guard top.presentingViewController != nil, let sheet = top.sheetPresentationController,
                  !SheetGlass.isGlassPage(sheet) else { return }
            sheet.hqGlassPage()
        }
    }

    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ probe: Probe, context: Context) {}
}
