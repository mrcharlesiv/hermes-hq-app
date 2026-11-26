// [favorites-live-tiles] A Dashboard tile on Favorites (docs/spec/3x-morepages.md §25 Q15–Q21). A public-beta tester,
// 2026-11-22: "it would be cool if for the new Favourites feature that you could add actual tiles instead of just a
// link to tiles." The owner: "I like this. Let's do it."
//
// The tile itself, not a link to the Dashboard: the same `PinTileView` the Dashboard draws (soft card, picture, health
// mark), its picture from `PinPictures` (as Bot Info's On Tiles reuses them), and a page whose head says live running
// live through the Favorites page's own `LiveTiles`. Small is one column and square, as a Dashboard Small tile; Wide is
// both columns and as tall as a Small one, as a Dashboard Medium tile.

import SwiftUI
import UIKit
import WebKit

/// The current account's pins and their pictures, for Favorites and its Add Action (one per account; made again when
/// the account changes).
@MainActor final class FavoriteTiles {
    let store: ArtifactsStore
    let pins: ArtifactPins
    let previews: ArtifactPreviews
    let pictures: PinPictures

    init(store: ArtifactsStore) {
        self.store = store
        pins = ArtifactPins.of(accountId: store.account.id)
        previews = ArtifactPreviews(client: store.client, account: store.account)
        pictures = PinPictures(account: store.account, previews: previews)
    }

    /// The signed-in account's Artifacts store (nil while there are no tabs, or signed out).
    static func store(_ root: MainTabController? = MainTabController.current) -> ArtifactsStore? { root?.pages?.artifactsStore }

    var accountId: String { store.account.id }

    /// The pins the Dashboard shows (none removed in Artifacts), in its order.
    var shown: [ArtifactPin] { store.hidden.visible(pins.pins) }

    /// A pin on the Dashboard by id, named as every list names it (nil: not pinned now).
    func pin(_ id: String?) -> ArtifactPin? {
        guard let id, !id.isEmpty, let pin = shown.first(where: { $0.id == id }) else { return nil }
        return pins.shown(pin)
    }

    /// Every pin on the Dashboard: id → name (`QuickTileWorld.pins`).
    var names: [String: String] { Dictionary(shown.map { ($0.id, pins.name($0)) }, uniquingKeysWith: { first, _ in first }) }

    /// The picture's shape, the tile's own (a page is drawn in the window its tile shows).
    static func shape(_ size: CGSize) -> PageSnapshots.Shape {
        .frame(width: size.width, height: size.height, zoom: max(1, HQFont.scale))
    }
}

extension ArtifactPin {
    /// [favorites-live-tiles] A pin that is gone, drawn from its id (`<profile>\u{1F}<value>`) and the name it had:
    /// its type's glyph, the missing mark and its name.
    static func standIn(id: String?, name: String) -> ArtifactPin {
        let parts = (id ?? "").split(separator: "\u{1F}", maxSplits: 1).map(String.init)
        let value = parts.count == 2 ? parts[1] : (id ?? "")
        let link = value.hasPrefix("http://") || value.hasPrefix("https://")
        var pin = ArtifactPin(kind: link ? .link : .file, value: value, label: (value as NSString).lastPathComponent,
                              profile: parts.count == 2 ? parts[0] : nil, sessionId: "", sessionTitle: "")
        pin.title = name
        return pin
    }
}

/// [favorites-live-tiles] How big a Dashboard tile is on Favorites, from the grid's width (the collection view's).
/// The rule for a row holding a Dashboard tile and an action tile: the row is as tall as the taller of the two (the
/// tile's square, or an action tile's words at a large text size), and both fill it, so neither is ever cut.
nonisolated enum FavoriteTileSize {
    /// The card's width and the picture's height. `side`: the section's side room; `gap`: between the columns.
    static func picture(width: CGFloat, side: CGFloat, gap: CGFloat, wide: Bool, stacked: Bool) -> CGSize {
        let whole = max(0, width - 2 * side)
        let column = max(0, (whole - gap) / 2)
        // Small: one column, square. Wide (and every tile in the one-column grid): both columns, a Small tile's height.
        return wide || stacked ? CGSize(width: whole, height: column) : CGSize(width: column, height: column)
    }

    /// The tile's height on the page: its picture, and the name's line under it while Show Names is on.
    static func height(picture: CGSize, names: Bool, nameHeight: CGFloat) -> CGFloat {
        picture.height + (names ? nameHeight : 0)
    }
}

/// [favorites-live-tiles] The Dashboard's tile on Favorites: `PinTileView` as the Dashboard draws it, at least its own
/// height and filling a taller row. A gone pin is its stand-in at 40 %.
struct FavoriteTileFace: View {
    var pin: ArtifactPin
    var picture: UIImage?
    var busy: Bool
    var health: TileJobs.Health
    var live: WKWebView?
    var failed: Bool
    var working: String?
    var height: CGFloat
    var dimmed: Bool

    var body: some View {
        PinTileView(pin: pin, picture: picture, fills: pin.kind == .image, busy: busy, showsName: ArtifactPins.showsNames,
                    health: health, editing: false, live: live, failed: failed, working: working, unpin: nil)
            .frame(minHeight: height, idealHeight: height, maxHeight: .infinity)
            .opacity(dimmed ? 0.4 : 1)
    }
}

/// [favorites-live-tiles] Pictures for Add Action's rows and Set Up's preview: its own `FavoriteTiles` (the Favorites
/// page keeps its own), and a tick when one lands so SwiftUI draws it.
@MainActor @Observable final class FavoriteTilePictures {
    @ObservationIgnored let source: FavoriteTiles
    private(set) var tick = 0

    init(_ source: FavoriteTiles) {
        self.source = source
        source.pictures.onUpdate = { [weak self] _ in self?.tick += 1 }
        source.previews.onUpdate = { [weak self] _ in self?.tick += 1 }
    }

    func picture(_ pin: ArtifactPin, dark: Bool, highContrast: Bool = false, size: CGSize) -> UIImage? {
        _ = tick
        Theme.touch()
        return source.pictures.picture(pin, dark: dark, highContrast: highContrast, pixels: max(size.width, size.height) * 3, shape: FavoriteTiles.shape(size))
    }

    /// A small square of it, for a row (as Bot Info's grid asks).
    func thumb(_ pin: ArtifactPin, dark: Bool, highContrast: Bool = false, side: CGFloat) -> UIImage? {
        _ = tick
        Theme.touch()
        return source.pictures.picture(pin, dark: dark, highContrast: highContrast, pixels: side * 3, shape: .box(aspect: 1))
    }
}

/// [favorites-live-tiles] Add Action's row picture for a Dashboard tile: a small square of its picture, else its glyph.
struct DashboardTileThumb: View {
    var pin: ArtifactPin
    var pictures: FavoriteTilePictures?
    var side: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let picture = pictures?.thumb(pin, dark: scheme == .dark, highContrast: contrast == .increased, side: side)
        let shape = RoundedRectangle(cornerRadius: side * 0.26, style: .continuous)
        Rectangle()
            .fill(picture.flatMap { pin.isPage ? PinPictures.edgeColor($0) : nil }.map { Color(uiColor: $0) } ?? Color.hqFill3)
            .overlay {
                if let picture {
                    if pin.isPage { PagePictureView(picture: picture, padding: 1) } else { Image(uiImage: picture).resizable().scaledToFill() }
                } else {
                    Image(systemName: PinCardView.glyph(pin)).font(.system(size: side * 0.48, weight: .regular))   // a11y-font-ok: sized to its square, as QuickTileIcon
                        .foregroundStyle(Color.hqTint)
                }
            }
            .frame(width: side, height: side)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color.hqStroke, lineWidth: HQShape.line(0.5)) }
            .accessibilityHidden(true)
    }
}

/// [favorites-live-tiles] Set Up's preview of a Dashboard tile: the real tile at the size it will have on Favorites
/// (Small: half the row, square; Wide: the whole row, as tall as a Small one), its name the one being typed.
struct DashboardTilePreview: View {
    var tile: QuickTile
    var pictures: FavoriteTilePictures?
    var stacked: Bool
    @State private var width: CGFloat = 0
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let _ = Theme.touch()
        let size = FavoriteTileSize.picture(width: width > 0 ? width : 360, side: 0, gap: HQFont.scaled(12), wide: tile.wide, stacked: stacked)
        let height = FavoriteTileSize.height(picture: size, names: ArtifactPins.showsNames, nameHeight: PinTileView.nameHeight)
        let kept = pictures?.source.pin(tile.pin)
        let pin: ArtifactPin = {
            var pin = kept ?? ArtifactPin.standIn(id: tile.pin, name: tile.name)
            pin.title = tile.name.isEmpty ? nil : tile.name
            return pin
        }()
        let dark = scheme == .dark
        let high = contrast == .increased
        let picture = kept.flatMap { pictures?.picture($0, dark: dark, highContrast: high, size: size) }
        let failed = kept.map { pictures?.source.pictures.failed($0) ?? false } ?? true
        let busy = picture == nil && kept.map { pictures?.source.pictures.waiting($0, dark: dark, highContrast: high, shape: FavoriteTiles.shape(size)) ?? false } == true
        HStack {
            Spacer(minLength: 0)
            FavoriteTileFace(pin: pin, picture: picture, busy: busy, health: .none, live: nil,
                             failed: failed, working: nil, height: height, dimmed: kept == nil)
                .frame(width: size.width, height: height)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview: \(tile.name), Dashboard tile")
        .accessibilityIdentifier("quick.setup.preview")
    }
}
