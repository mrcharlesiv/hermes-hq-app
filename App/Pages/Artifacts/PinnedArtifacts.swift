// Pinned artifacts on screen (tester, 2026-10-31): the cards on Artifacts' Pinned shelf and on the Pinned page.
// A page shows its picture, as its card in the chat does (`PageSnapshots`: its first chart, drawn with its scripts);
// an image its thumbnail; a file or link a large type glyph. A tap opens it as it is now: a page live, its buttons
// working. Pins are added from Artifacts (hold or swipe a row, hold a tile) and from a chat (hold a page card, a
// picture, a file or a file path).
// [dashboard] Grid (tester feedback, 2026-11-01: "reduce or remove footer and stack these in a grid layout it will
// actually feel like a dashboard"): the pins as picture tiles, Small, Medium or Large as Home Screen widgets are, with
// at most their names under them; dragged into any order.

import SwiftUI
import WebKit
import UIKit

/// The card. Its size is fixed by the layout; the picture arriving never moves it.
struct PinCardView: View {
    var pin: ArtifactPin
    var picture: UIImage?
    /// A page's picture is the page's chart fitted whole; an image fills the card.
    var fills: Bool
    var subtitle: String
    var busy: Bool
    /// [tiles] How its updates are going (a mark on the picture's corner).
    var health: TileJobs.Health = .none
    /// [mac] The pointer is over it (`PinHover`).
    var hover: PinHover? = nil
    /// Mac polish #46: a picture that's gone (`PinPictures.failed`).
    var failed = false
    /// [tiles] Its bot is working on it ("Otto is changing it…"), and its change was just done.
    var working: String? = nil
    var ringed = false
    var menu: () -> UIMenu
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Mac polish #46: a pinned picture that's gone wears Artifacts' broken-picture mark, in grey.
    static let goneGlyph = "photo.badge.exclamationmark"

    static func glyph(_ pin: ArtifactPin) -> String {
        if pin.isPage { return "chart.xyaxis.line" }
        if pin.kind == .image { return "photo" }
        return ArtifactRowView.glyph(pin.record)
    }

    var body: some View {
        let desktop = Theme.isDesktop
        let radius = HQShape.radius(14, .card)
        VStack(spacing: 0) {
            // The picture lies over a flexible area and is cut to it: a filled image never sizes the card.
            Rectangle()
                .fill(picture.flatMap { fills ? nil : PinPictures.edgeColor($0) }.map { Color(uiColor: $0) } ?? Color.hqFill3)
                .overlay {
                    if let picture {
                        if fills {
                            Image(uiImage: picture).resizable().scaledToFill()
                        } else {
                            PagePictureView(picture: picture, padding: 8)
                        }
                    } else if busy {
                        ProgressView()
                    } else {
                        Image(systemName: failed ? Self.goneGlyph : Self.glyph(pin)).hqSymbolFont(30, weight: .light, cap: 44)
                            .foregroundStyle(Color.hqLabel3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay { if let working { TileChangingVeil(words: working) } }
                .clipped()
            .overlay(alignment: .bottom) { Rectangle().fill(Color.hqStroke).frame(height: 0.5) }
            .overlay(alignment: .topTrailing) { TileHealthMark(health: health).padding(8) }
            HStack(spacing: 8) {
                // At the accessibility sizes the name has the row (the picture above says what it is).
                if !typeSize.isAccessibilitySize {
                    // Mac polish #46: a picture that's gone wears the broken mark here too, in grey, not the blue photo.
                    Image(systemName: failed ? Self.goneGlyph : pin.isPage ? "safari" : Self.glyph(pin))
                        .hqSymbolFont(15, cap: 22).foregroundStyle(failed ? Color.hqLabel3 : Color.hqTint)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(pin.name)
                        .font(Font.hq(.subheadline).weight(.semibold))
                        .foregroundStyle(Color.hqLabel)
                        .lineLimit(1).truncationMode(.middle)
                    Text(subtitle)
                        .font(Font.hq(.caption))
                        .foregroundStyle(Color.hqLabel2)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                UIMenuButton(menu: menu, label: "Actions for \(pin.name)")
                    .frame(width: 44, height: 44)   // [ui-sizing] every other ⋯ is 44 × 44 (was 32 × 36)
                    .padding(.vertical, -4)
            }
            .padding(.leading, 12)
            .padding(.trailing, 2)
            .padding(.vertical, typeSize.isAccessibilitySize ? 10 : 7)
            .fixedSize(horizontal: false, vertical: true)
        }
        .background(Color.hqGroupedCard)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay { PinHoverFill(hover: hover, shape: RoundedRectangle(cornerRadius: radius, style: .continuous)) }
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.hqStroke, lineWidth: desktop ? 1 : 0.5)
        }
        .overlay { if ringed { TileChangedRing().clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous)) } }
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// [mac] Mac polish #110: a tile's or card's hover, drawn on its own shape. The list's row hover (`MacHover`) filled the
/// whole square cell: a grey band under the tile's name and grey corners round the rounded tile, staying while the
/// pointer rested. The page hands each pin one (`MacHover.ownsHover`); off the Mac there is none.
@Observable final class PinHover {
    private(set) var on = false
    func set(_ hovering: Bool) { if hovering != on { on = hovering } }
}

/// The hover's faint fill (the rows' own), on the tile's or card's shape.
private struct PinHoverFill<S: Shape>: View {
    var hover: PinHover?
    var shape: S

    var body: some View {
        if hover?.on == true { shape.fill(Color.hqLabel.opacity(0.05)).allowsHitTesting(false) }
    }
}

/// A page's picture in a tile or card: edge to edge, from its top, when it is about the tile's shape (a page drawn in
/// the tile's window, `PageSnapshots.Shape`); else fitted whole with a margin of the page's own colour (a chart, a strip
/// of a long page). Owner 2026-11-02: a pinned dashboard.html sat small inside its tile.
struct PagePictureView: View {
    var picture: UIImage
    var padding: CGFloat

    /// The most of the picture's width or height filling may cut off.
    static let cropAllowed: CGFloat = 0.12

    static func fills(_ picture: CGSize, in frame: CGSize) -> Bool {
        guard picture.width > 0, picture.height > 0, frame.width > 0, frame.height > 0 else { return false }
        let ratio = (picture.width / picture.height) / (frame.width / frame.height)
        return ratio <= 1 / (1 - cropAllowed) && ratio >= 1 - cropAllowed
    }

    var body: some View {
        GeometryReader { geometry in
            if Self.fills(picture.size, in: geometry.size) {
                Image(uiImage: picture).resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                    .clipped()
            } else {
                Image(uiImage: picture).resizable().scaledToFit().padding(padding)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }
}

/// [dashboard] Grid's tile: the picture alone, the name under it as a Home Screen widget's (Show Names), its menu on a
/// hold or a right-click. A file or link has no picture: its glyph stands in the tile, with its name inside too while
/// names under the tiles are off (never both).
struct PinTileView: View {
    var pin: ArtifactPin
    var picture: UIImage?
    var fills: Bool
    var busy: Bool
    var showsName: Bool
    /// [tiles] How its updates are going (a mark on the corner; none while editing, where the unpin badge is).
    var health: TileJobs.Health = .none
    /// [dashboard] Edit Tiles: the tile wiggles, with an unpin badge and a corner handle (the page's pan sizes it).
    var editing = false
    /// [live-tiles] The tile's page running live (its picture stays under it until the page has drawn).
    var live: WKWebView? = nil
    /// [mac] The pointer is over it (`PinHover`).
    var hover: PinHover? = nil
    /// Mac polish #46: its picture is gone: the broken-picture mark in grey, and its name inside even with names off (a
    /// blank box said nothing). It looked like a picture still loading.
    var failed = false
    /// [tiles] Its bot is working on it ("Otto is changing it…"), and its change was just done.
    var working: String? = nil
    var ringed = false
    var unpin: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tilted = false

    /// The handle's box in the tile's bottom-right corner (the page starts a resize from a touch inside it).
    static let handleBox: CGFloat = 44

    /// The name's line under the tile (the layout keeps this much room under every row of tiles): Caption 1, growing
    /// with the text to 17 pt.
    static var nameFont: UIFont { HQFont.style(.caption1, cap: 17) }
    static var nameHeight: CGFloat { ceil(nameFont.lineHeight) + 5 }

    var body: some View {
        let radius = HQShape.radius(18, .card)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        VStack(spacing: 5) {
            Rectangle()
                .fill(picture.flatMap { fills ? nil : PinPictures.edgeColor($0) }.map { Color(uiColor: $0) } ?? Color.hqGroupedCard)
                .overlay {
                    if let picture {
                        if fills {
                            Image(uiImage: picture).resizable().scaledToFill()
                        } else {
                            PagePictureView(picture: picture, padding: 6)
                        }
                    } else if busy {
                        ProgressView()
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: failed ? PinCardView.goneGlyph : PinCardView.glyph(pin)).hqSymbolFont(26, weight: .light, cap: 40)
                                .foregroundStyle(failed ? Color.hqLabel3 : Color.hqTint)
                            if !showsName && (failed || !pin.isPage && pin.kind != .image) {
                                Text(pin.name)
                                    .font(Font(Self.nameFont as CTFont).weight(.medium))
                                    .foregroundStyle(Color.hqLabel)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(3).truncationMode(.middle)
                                    .padding(.horizontal, 10)
                            }
                        }
                    }
                }
                .overlay {
                    if let live, !editing { LiveTileHost(web: live) }   // [live-tiles]
                }
                .overlay { if let working { TileChangingVeil(words: working) } }   // [tiles]
                .overlay { if ringed { TileChangedRing() } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(shape)
                .overlay { PinHoverFill(hover: hover, shape: shape) }
                .overlay { shape.strokeBorder(Color.hqStroke, lineWidth: Theme.isDesktop ? 1 : 0.5) }
                .overlay(alignment: .topLeading) {
                    if editing, let unpin {
                        Button(action: unpin) {
                            Image(systemName: "minus")
                                .font(.system(size: 13, weight: .bold))   // a11y-font-ok: sized to its 26 pt disc, as Home Screen's badge
                                .foregroundStyle(Color.hqLabel)
                                .frame(width: 26, height: 26)
                                .background(.regularMaterial, in: Circle())
                                .overlay { Circle().strokeBorder(Color.hqStroke, lineWidth: 0.5) }
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .offset(x: -16, y: -16)   // on the corner, as Home Screen's, off the tile's content
                        .buttonStyle(.plain)
                        .accessibilityLabel("Unpin \(pin.name)")
                        .accessibilityIdentifier("pin.unpin-badge")
                        .transition(.hqMotion(.scale.combined(with: .opacity)))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if !editing { TileHealthMark(health: health).padding(7) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if editing {
                        ResizeHandleMark()
                            .frame(width: Self.handleBox, height: Self.handleBox)
                            .accessibilityHidden(true)   // VoiceOver sizes a tile from its menu
                            .transition(.opacity)
                    }
                }
                .rotationEffect(.degrees(editing && !reduceMotion ? (tilted ? 1.1 : -1.1) : 0))
                .onAppear { startWiggle() }
                .onChange(of: editing) { startWiggle() }
            if showsName {
                Text(pin.name)
                    .font(Font(Self.nameFont as CTFont))
                    .foregroundStyle(Color.hqLabel2)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.nameHeight - 5)
            }
        }
        .contentShape(Rectangle())
    }

    /// Home Screen's wiggle, each tile a little out of step (its id picks the speed).
    private func startWiggle() {
        guard editing, !reduceMotion else { tilted = false; return }
        let period = 0.13 + Double(abs(pin.id.hashValue) % 5) * 0.008
        withAnimation(.easeInOut(duration: period).repeatForever(autoreverses: true)) { tilted = true }
    }
}

/// [dashboard] The corner handle on a tile in Edit Tiles: a thick quarter-round on a frosted disc, as a window's corner.
private struct ResizeHandleMark: View {
    var body: some View {
        ZStack {
            Circle().fill(.regularMaterial).frame(width: 28, height: 28)
                .overlay { Circle().strokeBorder(Color.hqStroke, lineWidth: 0.5) }
            Path { path in
                path.move(to: CGPoint(x: 18, y: 8))
                path.addQuadCurve(to: CGPoint(x: 8, y: 18), control: CGPoint(x: 18, y: 18))
            }
            .stroke(Color.hqLabel, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
            .frame(width: 26, height: 26)
            .offset(x: -1, y: -1)
        }
        .padding([.trailing, .bottom], 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}

/// Pictures for the pins on screen: a page drawn by `PageSnapshots`, an image read by the page's `ArtifactPreviews`.
/// A page's last picture is kept in `ArtifactThumbs` (memory and disk) and shows at once; it is drawn again once a run,
/// and when its chat is read again, the kept one staying up meanwhile (owner 2026-11-01: every visit drew every pinned
/// page again from nothing).
@MainActor
/// [tiles] A tile's mark when its updates need a look (owner 2026-11-03: "a tile that shows when it's stale or
/// broken"): red ! when the last update failed, a clock when it's late, pause when paused, a spinner while its job runs.
/// Nothing when all is well. A small disc on glass-like material, so it reads on any page's colours.
struct TileHealthMark: View {
    var health: TileJobs.Health

    static let size: CGFloat = 22

    var body: some View {
        switch health {
        case .none, .fine:
            EmptyView()
        case .failed:
            Image(systemName: "exclamationmark")
                .font(.system(size: 12, weight: .heavy))   // a11y-font-ok: sized to its 22 pt disc, as a badge
                .foregroundStyle(.white)
                .frame(width: Self.size, height: Self.size)
                .background(Color.red, in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1) }
                .accessibilityIdentifier("tile.health.failed")
        case .late:
            disc(Image(systemName: "clock").font(.system(size: 11, weight: .semibold)), id: "late")   // a11y-font-ok: badge
        case .paused:
            disc(Image(systemName: "pause.fill").font(.system(size: 9, weight: .bold)), id: "paused")   // a11y-font-ok: badge
        case .updating:
            disc(ProgressView().controlSize(.mini), id: "updating")
        }
    }

    private func disc(_ content: some View, id: String) -> some View {
        content
            .foregroundStyle(Color.hqLabel)
            .frame(width: Self.size, height: Self.size)
            .background(.regularMaterial, in: Circle())
            .overlay { Circle().strokeBorder(Color.hqStroke, lineWidth: 0.5) }
            .accessibilityIdentifier("tile.health.\(id)")
    }

    /// Read out after the tile's name.
    static func words(_ health: TileJobs.Health) -> String? {
        switch health {
        case .none, .fine: nil
        case .failed: "last update failed"
        case .late: "not updated on time"
        case .paused: "updates paused"
        case .updating: "updating"
        }
    }
}

final class PinPictures {
    private let account: GatewayAccount
    private let previews: ArtifactPreviews
    private let thumbs = ArtifactThumbs.shared
    private var asked: Set<String> = []
    private var diskAsked: Set<String> = []
    /// The shapes each pin's page was asked in this run (its tile changed size, or Grid became Cards).
    private var shapesAsked: [String: Set<PageSnapshots.Shape>] = [:]
    /// Each pin's newest page picture in any shape: it stands in (fitted) while a new size's picture draws.
    private var latest: [String: UIImage] = [:]
    /// A pin's picture landed (its id).
    var onUpdate: ((String) -> Void)?

    init(account: GatewayAccount, previews: ArtifactPreviews) {
        self.account = account
        self.previews = previews
    }

    func context(_ pin: ArtifactPin) -> MediaContext {
        MediaContext(accountId: account.id, profile: pin.profile, storedSessionId: pin.sessionId)
    }

    /// The picture now (nil while the first one draws, or when there is none), asking for a fresh one when due.
    /// `shape`: the window a page is drawn in, the shape of the tile or card it shows in.
    func picture(_ pin: ArtifactPin, dark: Bool, pixels: CGFloat, shape: PageSnapshots.Shape) -> UIImage? {
        if pin.kind == .image {
            switch previews.state(pin.record) {
            case .image(let image): previews.request(pin.record, pixels: pixels); return image   // a bigger one, if due
            case .loading: previews.request(pin.record, pixels: pixels); return nil
            case .failed: return nil
            }
        }
        guard pin.isPage, let path = pin.gatewayPath else { return nil }
        shapesAsked[pin.id, default: []].insert(shape)
        let key = pageKey(pin, dark: dark, shape: shape)
        let context = context(pin)
        let generation = PageSnapshots.shared.generation(context)
        if let hit = PageSnapshots.shared.cached(path: path, context: context, dark: dark, shape: shape) {
            // Drawn when, unknown (a chat's card asked for it): as old as can be, so a chat read again redraws it.
            if !thumbs.pageIsCurrent(account, key, generation: generation) {
                thumbs.keepPage(hit, account, key, generation: generation, askedAt: .distantPast)
            }
            latest[pin.id] = hit
            return hit
        }
        let kept = thumbs.page(account, key)
        if kept == nil, diskAsked.insert(key).inserted {
            Task { [weak self, account, thumbs] in
                guard await thumbs.pageFromDisk(account, key) != nil else { return }
                self?.onUpdate?(pin.id)
            }
        }
        if !thumbs.pageIsCurrent(account, key, generation: generation), asked.insert(key).inserted {
            let askedAt = Date()
            PageSnapshots.shared.picture(path: path, name: pin.label, context: context, dark: dark, shape: shape) { [weak self] image in
                guard let self else { return }
                self.asked.remove(key)
                // Drawn (or not drawable) at this generation either way: a page that fails isn't asked again at once.
                self.thumbs.keepPage(image, self.account, key, generation: generation, askedAt: askedAt)
                if let image { self.latest[pin.id] = image }
                self.onUpdate?(pin.id)
            }
        }
        // The last picture stays up while a newer one draws.
        if let kept { latest[pin.id] = kept }
        return kept ?? thumbs.page(account, pageKey(pin, dark: !dark, shape: shape)) ?? latest[pin.id]
    }

    /// Pages whose head was asked for this run (`readHead`).
    private var headsAsked: Set<String> = []

    /// Mac polish #45: a pinned page's head (its title and job) read without drawing it, once a run. A row in List draws
    /// no picture, so its name stayed its file's ("Live") while its tile, drawn, said "Sales Today".
    func readHead(_ pin: ArtifactPin, done: @escaping (TileNames.Head) -> Void) {
        guard pin.isPage, pin.pageTitle == nil, let path = pin.gatewayPath, headsAsked.insert(pin.id).inserted else { return }
        let context = context(pin)
        if let head = PageSnapshots.shared.head(path: path, context: context) { return done(head) }
        Task {
            guard let url = try? await MediaLoader.shared.file(path: path, name: pin.label, context: context, progressKey: "head|" + path),
                  let handle = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: 64_000)) ?? Data()
            done(TileNames.head(String(decoding: data, as: UTF8.self)))
        }
    }

    /// Mac polish #46: a pinned picture the gateway couldn't give (gone, or never readable): not one still loading.
    func failed(_ pin: ArtifactPin) -> Bool {
        guard pin.kind == .image, case .failed = previews.state(pin.record) else { return false }
        return true
    }

    /// Whether the picture is still coming (a spinner instead of the type glyph).
    func waiting(_ pin: ArtifactPin, dark: Bool, shape: PageSnapshots.Shape) -> Bool {
        if pin.kind == .image, case .loading = previews.state(pin.record) { return true }
        return pin.isPage && asked.contains(pageKey(pin, dark: dark, shape: shape))
    }

    /// Draw the pins' pages again (pull to refresh, or their chat was read again): a bot rewrites its page in place.
    /// `drawnBefore`: only pages last drawn before then (one drawn since the chat was listed is already fresh).
    func redraw(_ pins: [ArtifactPin], drawnBefore: Date = .distantFuture) {
        for pin in pins {
            if pin.kind == .image { previews.clearFailure(pin.record.id) }
            guard pin.isPage, ![true, false].contains(where: { dark in
                (shapesAsked[pin.id] ?? []).contains { thumbs.pageDrawnSince(account, pageKey(pin, dark: dark, shape: $0), drawnBefore) }
            })
            else { continue }
            // A new generation for the pin's chat: the next ask draws it again (an open card in that chat redraws too).
            PageSnapshots.noteTurnEnded(context(pin))
        }
    }

    private func pageKey(_ pin: ArtifactPin, dark: Bool, shape: PageSnapshots.Shape) -> String {
        pin.id + (dark ? "|d" : "|l") + "|" + shape.key
    }

    /// The picture's top-left pixel: the page's own background, around a chart fitted whole.
    static func edgeColor(_ image: UIImage) -> UIColor? {
        guard let cg = image.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 1 - CGFloat(cg.height), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        guard px[3] > 200 else { return nil }
        return UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    }
}

/// Pin and Unpin in menus, the same words and symbol everywhere.
@MainActor
enum PinActions {
    static func action(pinned: Bool, _ toggle: @escaping () -> Void) -> UIAction {
        let action = UIAction(title: pinned ? "Unpin" : "Pin as Tile", image: UIImage(systemName: pinned ? "pin.slash" : "pin")) { _ in toggle() }
        action.accessibilityIdentifier = pinned ? "artifact.unpin" : "artifact.pin"
        return action
    }

    /// Pins or unpins, with a light tap and a word ("Pinned" shows where to find it the first time).
    static func toggle(_ record: ArtifactRecord, pins: ArtifactPins, from vc: UIViewController?) {
        let id = ArtifactPin.key(profile: record.profile, value: record.value)
        if !pins.isPinned(record), pins.isFull {
            // Audit 863 (08b-6): a pin past the limit is refused and said (it pushed the last pin out unsaid).
            PagesHaptics.error()
            AppLog.trace("pages", "artifact pin refused: \(ArtifactPins.limit) pinned")
            if let vc { PagesHUD.show(fullWords, detail: fullDetail, symbol: "pin.slash", from: vc) }
            return
        }
        // Audit 863 (08b-11): an unpin can be undone, the tile coming back as it was (its size, name and page).
        let was = pins.pins.firstIndex { $0.id == id }.map { (index: $0, pin: pins.pins[$0]) }
        let now = pins.toggle(record)
        Haptics.play(now ? .success : .soft)
        AppLog.trace("pages", "artifact \(now ? "pinned" : "unpinned") (\(record.kind.rawValue))")
        guard let vc else { return }
        if now, !UserDefaults.standard.bool(forKey: firstPinKey) {
            UserDefaults.standard.set(true, forKey: firstPinKey)
            PagesHUD.show("Pinned to Your Tiles", symbol: "pin.fill", from: vc)
        } else if !now, let was {
            UndoPill.show(label: "Unpinned “\(was.pin.name)”", in: vc) { [weak pins] in
                pins?.restore(was.pin, at: was.index)
                AppLog.trace("pages", "artifact unpin undone")
            }
        } else {
            PagesHUD.show(now ? "Pinned as a Tile" : "Unpinned", symbol: now ? "pin.fill" : "pin.slash", from: vc)
        }
    }

    static let fullWords = "Your Tiles Are Full"
    static var fullDetail: String { "Unpin one to pin another (\(ArtifactPins.limit) at most)." }

    private static let firstPinKey = "hq.artifactPins.toldWhere"

    /// Owner 2026-11-02 ("artifacts saved from email footers … Remove them"): hides the artifact from every list, in every
    /// chat that names it, and unpins it. The file or link itself is untouched.
    static func removeAction(_ remove: @escaping () -> Void) -> UIAction {
        let action = UIAction(title: "Remove", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in remove() }
        action.accessibilityIdentifier = "artifact.remove"
        return action
    }

    static func remove(_ record: ArtifactRecord, hidden: ArtifactHidden, pins: ArtifactPins, from vc: UIViewController?) {
        hidden.hide(record, pins: pins)
        Haptics.play(.soft)
        AppLog.trace("pages", "artifact removed (\(record.kind.rawValue))")
        if let vc { PagesHUD.show("Removed", symbol: "trash", from: vc) }
    }

    /// [safer-deletes] Remove asks first, as every Delete does (owner 2026-11-03: "destructive actions sit next to everyday
    /// ones"): an action sheet from the row or tile (a popover by it on iPad and the Mac), then `remove`. Nothing is ever
    /// put back (`ArtifactHidden`). `name`: a tile's own name; else the file's or link's.
    static func confirmRemove(_ record: ArtifactRecord, name: String? = nil, hidden: ArtifactHidden, pins: ArtifactPins,
                              from vc: UIViewController, source: UIView?) {
        TextPrompt.confirm(title: removeTitle(name ?? record.label), message: removeMessage, action: "Remove Artifact",
                           style: .actionSheet, from: vc, sourceView: source) { [weak vc] in
            remove(record, hidden: hidden, pins: pins, from: vc)
        }
    }

    /// The Remove question, worded as the Delete questions are: what goes, what stays, and that it can't be undone.
    static func removeTitle(_ name: String) -> String { name.isEmpty ? "Remove This Artifact?" : "Remove “\(name)”?" }
    static let removeMessage = "It’s removed from Artifacts, Tiles and Bot Info in every chat that names it. "
        + "The file or link itself isn’t deleted. This can’t be undone."

    /// A row swiped left: Remove, which asks first (`confirmRemove`). [safer-deletes] One rule for every list's swipes: one
    /// that deletes asks before it does (Sessions, Kanban and Jobs already did; Bots has none). A full swipe opens the
    /// question too; it never removes by itself.
    static func removeSwipe(_ confirm: @escaping () -> Void) -> UISwipeActionsConfiguration {
        let action = UIContextualAction(style: .destructive, title: "Remove") { _, _, done in confirm(); done(false) }
        action.image = UIImage(systemName: "trash.fill")
        return UISwipeActionsConfiguration(actions: [action])
    }

    /// Grid, Cards or List (and Grid's Show Names; on Artifacts, Open Pinned): the Pinned page's bar button and the menu
    /// by Artifacts' Pinned header.
    static func viewMenu(openAll: (() -> Void)?, editTiles: (() -> Void)? = nil) -> UIMenu {
        let current = ArtifactPins.view
        let choices = PinsView.allCases.map { view in
            let action = UIAction(title: title(view), image: UIImage(systemName: symbol(view)), state: view == current ? .on : .off) { _ in
                PagesHaptics.selection(); ArtifactPins.view = view
            }
            action.accessibilityIdentifier = "pins.view.\(view.rawValue)"
            return action
        }
        var children: [UIMenuElement] = [UIMenu(title: "View As", options: [.displayInline, .singleSelection], children: choices)]
        if current == .grid {
            let names = UIAction(title: "Show Names", image: UIImage(systemName: "textformat"), state: ArtifactPins.showsNames ? .on : .off) { _ in
                PagesHaptics.selection(); ArtifactPins.showsNames.toggle()
            }
            names.accessibilityIdentifier = "pins.view.names"
            var grid: [UIMenuElement] = [names]
            if let editTiles { grid.append(editTilesAction(editTiles)) }
            children.append(UIMenu(options: .displayInline, children: grid))
        }
        if let openAll {
            let open = UIAction(title: "Open Tiles", image: UIImage(systemName: "rectangle.3.group")) { _ in openAll() }
            open.accessibilityIdentifier = "pins.open-page"
            children.append(UIMenu(options: .displayInline, children: [open]))
        }
        return UIMenu(children: children)
    }

    private static func title(_ view: PinsView) -> String {
        switch view {
        case .grid: "Grid"
        case .cards: "Cards"
        case .list: "List"
        }
    }

    private static func symbol(_ view: PinsView) -> String {
        switch view {
        case .grid: "square.grid.2x2"
        case .cards: "rectangle.grid.1x2"
        case .list: "list.bullet"
        }
    }

    /// The glyph of the view button: what a tap picks from.
    static var viewSymbol: String { symbol(ArtifactPins.view) }

    /// [dashboard] The sizes, for a tile in Grid: a row of four tile pictures at the top of its menu (owner 2026-11-02,
    /// "more like widgets"; Size was a submenu in the middle).
    static func sizeMenu(_ pin: ArtifactPin, pins: ArtifactPins) -> UIMenu {
        let sizes = PinTileSize.allCases.map { size in
            let action = UIAction(title: size.title, image: sizeImage(size), state: pin.tileSize == size ? .on : .off) { _ in
                PagesHaptics.selection()
                pins.setSize(size, id: pin.id)
                AppLog.trace("pages", "pin tile size \(size.rawValue)")
            }
            action.accessibilityIdentifier = "pin.size.\(size.rawValue)"
            return action
        }
        let menu = UIMenu(title: "Size", options: [.displayInline, .singleSelection], children: sizes)
        menu.preferredElementSize = .small
        return menu
    }

    /// A size as a picture: a grid two cells across and three down, the tile's cells filled.
    static func sizeImage(_ size: PinTileSize) -> UIImage {
        let cell: CGFloat = 8, gap: CGFloat = 2
        let box = CGSize(width: cell * 2 + gap, height: cell * 3 + gap * 2)
        let span = size.span
        let image = UIGraphicsImageRenderer(size: box).image { _ in
            for row in 0..<3 {
                for column in 0..<2 {
                    let rect = CGRect(x: CGFloat(column) * (cell + gap), y: CGFloat(row) * (cell + gap), width: cell, height: cell)
                    let filled = row < span.rows && column < min(span.columns, 2)
                    let path = UIBezierPath(roundedRect: rect.insetBy(dx: filled ? 0 : 0.6, dy: filled ? 0 : 0.6), cornerRadius: 2)
                    if filled {
                        UIColor.black.setFill(); path.fill()
                    } else {
                        UIColor.black.withAlphaComponent(0.45).setStroke(); path.lineWidth = 1.2; path.stroke()
                    }
                }
            }
            // The filled cells as one tile.
            if span.rows > 1 || span.columns > 1 {
                let across = CGFloat(min(span.columns, 2)), down = CGFloat(span.rows)
                UIColor.black.setFill()
                UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: across * cell + (across - 1) * gap,
                                                 height: down * cell + (down - 1) * gap), cornerRadius: 2.5).fill()
            }
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    /// [dashboard] Edit Tiles: the tiles wiggle, a corner handle sizes each, a badge unpins (Home Screen's edit mode).
    static func editTilesAction(_ start: @escaping () -> Void) -> UIAction {
        let action = UIAction(title: "Edit Tiles", image: UIImage(systemName: "square.resize")) { _ in start() }
        action.accessibilityIdentifier = "pins.edit"
        return action
    }

    /// A file a chat names, as an Artifacts record (for Pin from a chat).
    static func record(path: String, name: String, kind: ArtifactRecord.Kind? = nil, context: MediaContext,
                       sessionId: String?, sessionTitle: String) -> ArtifactRecord {
        let kind = kind ?? ArtifactCollector.kind(path)
        let session = sessionId ?? context.storedSessionId ?? ""
        return ArtifactRecord(id: "chat:" + path, kind: kind, value: path, href: ArtifactCollector.href(path),
                              label: name.isEmpty ? ArtifactCollector.label(path, kind: kind) : name, sessionId: session,
                              profile: context.profile, sessionTitle: sessionTitle, timestamp: Date().timeIntervalSince1970 * 1000)
    }
}
