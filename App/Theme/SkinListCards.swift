// skin-list-cards: a grouped list's rows take the skin's card (owner 2026-11-02, Rosé Pine's More page: "This grey
// against the purple looks awful"). `HQPalette.card` was in the skin's hue, but a list row left to iOS (no background
// colour of its own: the More page, Settings, every SwiftUI Form) drew iOS's raised card, #1C1C1E on Rosé Pine's
// #191724. Rather than give each of the ~120 lists its own row background, a row's background is looked at as it is
// updated for its state (`updateConfiguration(using:)`, exchanged on UICollectionViewListCell and UITableViewCell,
// public API only): one that would draw iOS's grouped card is given
// `HQPalette.card`, and `HQPalette.cellPressed` while pressed. Only with a skin that paints its own grouped page and
// the Desktop Look off (which clears its rows itself, DesktopLists.swift); the standard look and the iOS System skin
// keep iOS's own rows. A row with its own colour, picture or blur (a glass sheet's frosted card, a clear row) is left.

import ObjectiveC
import UIKit

@MainActor enum SkinListCards {
    private static var installed = false
    fileprivate static let ownKey = malloc(1)!

    static func install() {
        guard !installed else { return }
        installed = true
        exchange(UICollectionViewListCell.self, #selector(UICollectionViewListCell.updateConfiguration(using:)),
                 #selector(UICollectionViewListCell.hqSkinUpdateConfiguration(using:)))
        exchange(UITableViewCell.self, #selector(UITableViewCell.updateConfiguration(using:)),
                 #selector(UITableViewCell.hqSkinTableUpdateConfiguration(using:)))
        // A row's `configurationUpdateHandler` runs after `updateConfiguration(using:)` and may put iOS's card back
        // (the Mac's rows: `MacSelection.groupedRow`); the row's layout comes after both.
        exchange(UICollectionViewListCell.self, #selector(UIView.layoutSubviews), #selector(UICollectionViewListCell.hqSkinLayoutSubviews))
        exchange(UITableViewCell.self, #selector(UIView.layoutSubviews), #selector(UITableViewCell.hqSkinTableLayoutSubviews))
        exchange(UISegmentedControl.self, #selector(UIView.didMoveToWindow), #selector(UISegmentedControl.hqSkinDidMoveToWindow))
    }

    /// Added on the class itself first, so a superclass's method is never swapped for every subclass.
    private static func exchange(_ type: AnyClass, _ selector: Selector, _ hook: Selector) {
        guard let original = class_getInstanceMethod(type, selector), let replacement = class_getInstanceMethod(type, hook) else { return }
        if class_addMethod(type, selector, method_getImplementation(replacement), method_getTypeEncoding(replacement)) {
            class_replaceMethod(type, hook, method_getImplementation(original), method_getTypeEncoding(original))
        } else if let own = class_getInstanceMethod(type, selector) {
            method_exchangeImplementations(own, replacement)
        }
    }

    /// The skin is painting its own grouped page and the Desktop Look is off, for this view's theme generation.
    static func skinned(_ traits: UITraitCollection) -> Bool {
        let set = ThemeTable.set(generation: traits[ThemeGenerationTrait.self])
        // [mac-audit] #8: the Mac in dark too, whose page is the look's own there (`ThemedColor.macDarkGrouped`).
        return ThemedColor.paintsGroupedPage(traits) && !set.state.desktopLook
    }

    /// The background this row should have, or nil to leave the one given.
    static func adjusted(_ config: UIBackgroundConfiguration?, cell: UIView, pressed: Bool) -> UIBackgroundConfiguration? {
        guard var config else { return nil }
        // Ours only on a row this took over (its own colour is kept under `ownKey`). A row that picks
        // `HQPalette.cellPressed` itself (the Bots rows, group rows: their own `configurationUpdateHandler`) is not:
        // taken for ours, the way back below gave it its own colour of nil, which a cell draws as the tint, so a held bot
        // lifted as a solid blue row before its menu's card (owner 2026-11-04, "weird glitch when you hold down on a bot").
        let taken = objc_getAssociatedObject(cell, ownKey) != nil
        let ours = taken && (config.backgroundColor === HQPalette.card || config.backgroundColor === HQPalette.cellPressed)
        let traits = cell.traitCollection
        guard skinned(traits) else {
            // The skin went back to iOS's own look: give the row back its own iOS colour. Not nil: to a SwiftUI row nil
            // means the tint, so after Rosé Pine › Nous the Theme page's rows turned solid blue (owner 2026-11-02, 662).
            guard ours else { return nil }
            config.backgroundColor = objc_getAssociatedObject(cell, ownKey) as? UIColor
            objc_setAssociatedObject(cell, ownKey, nil, .OBJC_ASSOCIATION_RETAIN)
            return config
        }
        guard config.customView == nil, config.visualEffect == nil, config.backgroundColorTransformer == nil else { return nil }
        if !ours {
            guard isSystemCard(config, cell: cell) else { return nil }
            // The row's own card colour is kept to give back (NSNull: it had none of its own).
            if let own = config.backgroundColor, isSystem(own), cardNames.contains(where: own.description.contains) {
                objc_setAssociatedObject(cell, ownKey, own, .OBJC_ASSOCIATION_RETAIN)
            } else if objc_getAssociatedObject(cell, ownKey) == nil {
                objc_setAssociatedObject(cell, ownKey, NSNull(), .OBJC_ASSOCIATION_RETAIN)
            }
        }
        let wanted = pressed ? HQPalette.cellPressed : HQPalette.card
        guard config.backgroundColor !== wanted else { return nil }
        config.backgroundColor = wanted
        return config
    }

    /// The row would draw iOS's grouped card: in dark at the row's own level its colour is iOS's raised grouped one
    /// (UIKit names it `tableCellGroupedBackgroundColor`, not `secondarySystemGroupedBackground`), where the grouped card
    /// (#1C1C1E, raised #2C2C2E) and a plain list's row (#000000, raised #1C1C1E) differ; in light both are white. A row
    /// already seen drawing it keeps being ours while iOS swaps in its own press grey (or no colour).
    private static func isSystemCard(_ config: UIBackgroundConfiguration, cell: UIView) -> Bool {
        if objc_getAssociatedObject(cell, ownKey) != nil, config.backgroundColor.map(isSystem) ?? true { return true }
        // [mac] Catalyst's grouped card is its own grey (#323232), so it is known by name there.
        if let color = config.backgroundColor, isSystem(color), cardNames.contains(where: color.description.contains) { return true }
        let dark = cell.traitCollection.modifyingTraits { $0.userInterfaceStyle = .dark }
        let drawn = config.resolvedBackgroundColor(for: cell.tintColor).resolvedColor(with: dark)
        return drawn == UIColor.secondarySystemGroupedBackground.resolvedColor(with: dark)
    }

    private static let cardNames = ["name = tableCellGroupedBackgroundColor", "name = secondarySystemGroupedBackgroundColor"]

    /// One of iOS's own named colours (the card, its press grey), not one the app chose.
    private static func isSystem(_ color: UIColor) -> Bool {
        NSStringFromClass(type(of: color)).contains("DynamicSystemColor")
    }
}

/// [skin-segments] Owner 2026-11-02 (Theme's Themes / Chats / Backgrounds on a coloured skin): "The top tabs are not
/// themed." A segmented control (the page tabs, SwiftUI's segmented pickers) drew iOS's grey track and pill on the skin's
/// page. With a skin that paints its own page and the Desktop Look off, the track is the skin's card and the chosen
/// segment lifted from it as iOS's is (its card in light; in the dark a fifth of the way to the skin's ink, where the
/// pressed card read as no pill at all), in the skin's ink; otherwise iOS's own. Set as a control joins a window and
/// again when the theme changes under it.
@MainActor enum SkinSegments {
    private static let watchedKey = malloc(1)!
    private static let chosenFill = UIColor { @Sendable traits in
        let card = HQPalette.card.resolvedColor(with: traits)
        guard traits.userInterfaceStyle == .dark else { return card }
        let ink = HQPalette.label.resolvedColor(with: traits)
        var (r, g, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0)), (ir, ig, ib, ia) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        card.getRed(&r, green: &g, blue: &b, alpha: &a); ink.getRed(&ir, green: &ig, blue: &ib, alpha: &ia)
        return UIColor(red: r + (ir - r) * 0.2, green: g + (ig - g) * 0.2, blue: b + (ib - b) * 0.2, alpha: 1)
    }

    static func apply(_ control: UISegmentedControl) {
        if objc_getAssociatedObject(control, watchedKey) == nil {
            objc_setAssociatedObject(control, watchedKey, true, .OBJC_ASSOCIATION_RETAIN)
            control.registerForTraitChanges([ThemeGenerationTrait.self]) { (control: UISegmentedControl, _) in apply(control) }
        }
        let skinned = SkinListCards.skinned(control.traitCollection)
        let track: UIColor? = skinned ? HQPalette.card : nil
        if control.backgroundColor != track { control.backgroundColor = track }
        let chosen: UIColor? = skinned ? chosenFill : nil
        if control.selectedSegmentTintColor != chosen { control.selectedSegmentTintColor = chosen }
        for state in [UIControl.State.normal, .selected] {
            var attributes = control.titleTextAttributes(for: state) ?? [:]
            let ink: UIColor? = skinned ? (state == .selected ? HQPalette.label : HQPalette.label2) : nil
            guard (attributes[.foregroundColor] as? UIColor) != ink else { continue }
            attributes[.foregroundColor] = ink
            control.setTitleTextAttributes(attributes, for: state)
        }
    }
}

extension UISegmentedControl {
    @objc dynamic func hqSkinDidMoveToWindow() {
        hqSkinDidMoveToWindow()
        if window != nil { SkinSegments.apply(self) }
    }
}

private extension UICellConfigurationState {
    var hqPressed: Bool { isHighlighted || isSelected }
}

extension UICollectionViewListCell {
    @objc dynamic func hqSkinUpdateConfiguration(using state: UICellConfigurationState) {
        hqSkinUpdateConfiguration(using: state)
        if let fixed = SkinListCards.adjusted(backgroundConfiguration, cell: self, pressed: state.hqPressed) { backgroundConfiguration = fixed }
    }

    @objc dynamic func hqSkinLayoutSubviews() {
        hqSkinLayoutSubviews()
        if let fixed = SkinListCards.adjusted(backgroundConfiguration, cell: self, pressed: configurationState.hqPressed) { backgroundConfiguration = fixed }
    }
}

extension UITableViewCell {
    @objc dynamic func hqSkinTableUpdateConfiguration(using state: UICellConfigurationState) {
        hqSkinTableUpdateConfiguration(using: state)
        if let fixed = SkinListCards.adjusted(backgroundConfiguration, cell: self, pressed: state.hqPressed) { backgroundConfiguration = fixed }
    }

    @objc dynamic func hqSkinTableLayoutSubviews() {
        hqSkinTableLayoutSubviews()
        if let fixed = SkinListCards.adjusted(backgroundConfiguration, cell: self, pressed: configurationState.hqPressed) { backgroundConfiguration = fixed }
    }
}
