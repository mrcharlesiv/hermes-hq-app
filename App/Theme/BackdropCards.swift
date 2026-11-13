// [backdrop-cards] Owner 2026-11-11: "Some things need a background of sorts behind them when you use a wallpaper for
// the app." Owner 2026-11-12: a switch, off until turned on: Theme › Backgrounds › App Background › Soft Cards
// (`Backdrop.cards`, `hqn.appBackground.cards`); then, after the first build, "make it ALL right".
//
// While a page's picture shows and Soft Cards is on, every section of every list stands on ONE soft card
// (`SoftCardSurface`, App/Theme/SoftCard.swift): its title, its rows and its note. Nothing nests.
// - Plain lists (Bots, Sessions, Jobs, Tasks, Other Apps, Artifacts' days, Kanban): a section background
//   (`BackdropCards.card`), `side` from the page's edges.
// - Grouped pages (SwiftUI lists on `hqGroupedPage`, More, table pages): `BackdropPlates` draws the card behind each
//   section, and the rows give up iOS's own card on it (`SkinListCards`, which asks `BackdropPlates.softRows`).
// - What stands alone (a count, a note, an empty or error state): `hqPictureBacking`, `BackdropStateConfiguration`.
// With no picture, in a sheet, in the Desktop Look (which draws no picture) or with the switch off, nothing changes.

import SwiftUI
import UIKit

@MainActor enum BackdropCards {
    static let kind = "hqn.backdropCard"
    /// From the page's edges to the card, and from the card to the next section's.
    static let side: CGFloat = 10
    static let gap: CGFloat = 10
    /// Room inside the card above its first row and below its last.
    static let pad: CGFloat = 6

    /// [backdrop-cards] Owner 2026-11-12: on Bots the pinned faces' card floated above the bots' rows ("these two
    /// sections should be connected"). A section joined to the one above or below has no corners, room or gap on that
    /// side, so the two cards read as one.
    struct Join: OptionSet, Sendable {
        let rawValue: Int
        static let above = Join(rawValue: 1)
        static let below = Join(rawValue: 2)
    }

    fileprivate static func kind(_ join: Join) -> String { join.isEmpty ? kind : kind + ".\(join.rawValue)" }
    /// One card behind a run of joined sections (`BackdropCardLayout`).
    static let runKind = kind + ".run"
    fileprivate static let topKind = kind(.below), footKind = kind(.above), middleKind = kind([.above, .below])
    fileprivate static let pieceKinds = [topKind, middleKind, footKind]

    static func register(in layout: UICollectionViewLayout) {
        layout.register(BackdropCardView.self, forDecorationViewOfKind: kind)
        layout.register(BackdropCardView.self, forDecorationViewOfKind: runKind)
        layout.register(BackdropCardTopView.self, forDecorationViewOfKind: kind(.below))
        layout.register(BackdropCardFootView.self, forDecorationViewOfKind: kind(.above))
        layout.register(BackdropCardMiddleView.self, forDecorationViewOfKind: kind([.above, .below]))
    }

    private static let cardedKey = malloc(1)!

    /// `list`'s sections stand on cards just now (`PageBackdrop` says, as the picture and the switch come and go).
    static func mark(_ list: UIScrollView, carded: Bool) {
        guard (objc_getAssociatedObject(list, cardedKey) != nil) != carded else { return }
        objc_setAssociatedObject(list, cardedKey, carded ? true : nil, .OBJC_ASSOCIATION_RETAIN)
        (list as? UICollectionView)?.visibleCells.forEach { $0.setNeedsLayout() }
    }

    /// Whether `list` is one whose sections stand on cards just now.
    static func isCarded(_ list: UIView?) -> Bool {
        list.map { objc_getAssociatedObject($0, cardedKey) != nil } ?? false
    }

    /// For a row or a header drawn in SwiftUI on a tab's own list (which always shows the app's picture when there is
    /// one): Soft Cards is on and the picture shows. Owner 2026-11-13 (a screenshot of Bots): "Look at the padding on top
    /// and bottom of these. It's not even." A title brings room above it sized for the plain page, where it parts one
    /// group from the last; on a card that room is the card's own inset, so a title on a card stands as far under the
    /// card's top as its last row's words stand over the card's foot (about 17 pt). Each header takes its room from here.
    static var live: Bool { Backdrop.app.cards && Backdrop.app.shows }

    /// `perWhole` for each whole of UI Scale past 100 % (less under it). A card's ends stay even at every UI Scale: the
    /// words grow with it inside a title's or a row's fixed room, so the room over a title is tuned by this (measured
    /// at 85, 100 and 115 % on a one-colour picture, build/tools/measure.py).
    static func grown(_ perWhole: CGFloat) -> CGFloat { perWhole * (HQFont.scale - 1) }

    /// The same for a room that follows the words' size whatever made them bigger: UI Scale and the iPhone's own
    /// text size together (Sessions' captions, a fixed 24 pt tall, behave alike under both).
    static func grownWithText(_ perWhole: CGFloat) -> CGFloat { perWhole * (HQFont.preferred(.body).pointSize / 17 - 1) }

    /// And for the iPhone's own text size alone (1 at the standard size), where a view answers it otherwise than UI Scale.
    static var textSize: CGFloat { HQFont.preferred(.body).pointSize / 17 / max(HQFont.scale, 0.1) }

    /// `room` more over `list`'s first section (so its first card stands one gap under what is over the list); a list
    /// resting at its top stays at its top.
    static func setTopRoom(_ room: CGFloat, of list: UIScrollView) {
        guard abs(list.contentInset.top - room) > 0.1 else { return }
        let resting = abs(list.contentOffset.y + list.adjustedContentInset.top) < 1
        list.contentInset.top = room
        if resting { list.contentOffset.y = -list.adjustedContentInset.top }
    }

    /// Every row and header of `dataSource`'s list drawn again (they draw differently on a card).
    static func redraw<Section: Hashable & Sendable, Item: Hashable & Sendable>(_ dataSource: UICollectionViewDiffableDataSource<Section, Item>?) {
        guard let dataSource else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reloadSections(snapshot.sectionIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Whether `controller`'s lists draw cards just now: its picture shows (`PageBackdrop`).
    static func on(_ controller: UIViewController?) -> Bool {
        !Theme.isDesktop && Backdrop.app.cards && PageBackdrop.showsPicture(on: controller)
    }

    /// Puts `section` on a card when `on`: its rows move in `side` from the edges, and the card hugs its header and rows.
    /// - `header`: the section has a header of its own above its rows (a list's supplementary header). A section's top
    ///   inset falls between that header and the rows, so the card adds no room there: the header brings its own.
    /// - `keepWidth`: a section that lays out its own width (the Bots faces, centred in three columns) keeps it; the
    ///   card stands `side` from the page's edges behind it.
    /// - `join`: the card runs on into the section above or below.
    /// - `extraTop`, `extraBottom`: more room inside the card at that end, where what stands there brings less of its
    ///   own than a row does (so the card's two ends stay even).
    static func card(_ section: NSCollectionLayoutSection, on: Bool, header: Bool = false, keepWidth: Bool = false, join: Join = [],
                     extraTop: CGFloat = 0, extraBottom: CGFloat = 0) {
        guard on else { return }
        var insets = section.contentInsets
        if !keepWidth {
            insets.leading += side
            insets.trailing += side
        }
        let top = (join.contains(.above) || header ? 0 : pad) + extraTop, bottom = (join.contains(.below) ? 0 : pad) + extraBottom
        insets.top += top
        insets.bottom += bottom + (join.contains(.below) ? 0 : gap)
        section.contentInsets = insets
        let card = NSCollectionLayoutDecorationItem.background(elementKind: kind(join))
        card.contentInsets = NSDirectionalEdgeInsets(top: join.contains(.above) || header ? 0 : max(0, insets.top - top),
                                                     leading: keepWidth ? side : insets.leading,
                                                     bottom: join.contains(.below) ? 0 : max(0, insets.bottom - bottom),
                                                     trailing: keepWidth ? side : insets.trailing)
        card.zIndex = -1
        section.decorationItems.append(card)
    }
}

/// [soft-cards] Owner 2026-11-13 (a screenshot of Sessions on build 974, three projects on one card): each project
/// showed as a band of its own. A joined card was one piece of frosted glass per section, and each piece softens only
/// the stretch of picture behind its own frame, so over a picture that changes down the page the pieces come out in
/// different tones and the joins show. In this layout a run of joined sections has ONE card behind all of it (`runKind`,
/// placed at the run's first section and as tall as the whole run); the sections' own pieces only mark where it goes.
/// A list with a section that scrolls sideways (Kanban's chips, Artifacts' shelf) drops a card this layout adds (it is
/// shown, then taken back on the next pass, whatever its index path). Such a list sets `placesCards`: the run's card
/// is then a view this layout keeps in the list itself, placed again whenever a piece comes, goes or moves. (That one
/// does not move with an animated change; the runs in those lists never fold.)
class BackdropCardLayout: UICollectionViewCompositionalLayout {
    /// The run's card is a view of the list's own, not a decoration (see above). Set before the list first lays out.
    var placesCards = false
    private var placed: [SoftCardSurface] = []
    private var placing = false

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let all = super.layoutAttributesForElements(in: rect) else { return nil }
        guard !placesCards else { return all }
        let runs = runs(among: all.filter(Self.isPiece))
        return runs.isEmpty ? all : all + runs
    }

    /// Every run that `pieces` are part of, whole.
    private func runs(among pieces: [UICollectionViewLayoutAttributes]) -> [UICollectionViewLayoutAttributes] {
        var known: [Int: UICollectionViewLayoutAttributes] = [:]
        for piece in pieces { known[piece.indexPath.section] = piece }
        var runs: [Int: UICollectionViewLayoutAttributes] = [:]
        for section in known.keys.sorted() {
            guard let piece = known[section] else { continue }
            let run = run(through: piece, known: &known)
            runs[run.indexPath.section] = run
        }
        return Array(runs.values)
    }

    /// A piece of a joined card came, went or moved (`BackdropCardPieceView`): with `placesCards`, the runs' cards are
    /// put where the layout has them now, once this pass is over.
    func piecesChanged() {
        guard placesCards, !placing else { return }
        placing = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.placing = false
                self?.place()
            }
        }
    }

    private func place() {
        guard let list = collectionView, list.window != nil else { return }
        let near = CGRect(x: 0, y: list.bounds.minY - 800, width: max(1, list.bounds.width), height: list.bounds.height + 1600)
        let frames = runs(among: pieces(in: near)).map(\.frame).sorted { $0.minY < $1.minY }
        while placed.count < frames.count {
            let card = SoftCardSurface()
            card.layer.zPosition = -1   // under the rows, as a section's own card
            list.insertSubview(card, at: 0)
            placed.append(card)
        }
        for (index, card) in placed.enumerated() {
            card.isHidden = index >= frames.count
            guard index < frames.count else { continue }
            if card.superview !== list { list.insertSubview(card, at: 0) }
            if card.frame != frames[index] { card.frame = frames[index] }
        }
        // A strip that scrolls sideways inside a card (the Tiles shelf, Kanban's chips) ran on past the card's edge to
        // the screen's: it is cut at the card's sides.
        for strip in list.subviews {
            guard let strip = strip as? UIScrollView else { continue }
            let card = frames.first { $0.minY <= strip.frame.midY && strip.frame.midY <= $0.maxY }
            SidewaysClip.set(card.map { (left: $0.minX - strip.frame.minX, right: strip.frame.maxX - $0.maxX) }, on: strip)
        }
    }

    override func layoutAttributesForDecorationView(ofKind kind: String, at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard kind == BackdropCards.runKind else { return super.layoutAttributesForDecorationView(ofKind: kind, at: indexPath) }
        // The run that starts at this section: found from where the section stands.
        let section = indexPath.section
        guard let list = collectionView, section >= 0, section < list.numberOfSections else { return nil }
        let head = super.layoutAttributesForSupplementaryView(ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section))
        let row = list.numberOfItems(inSection: section) > 0 ? super.layoutAttributesForItem(at: IndexPath(item: 0, section: section)) : nil
        guard let place = [head?.frame, row?.frame].compactMap({ $0 }).first(where: { $0.height > 0 }) else { return nil }
        var known: [Int: UICollectionViewLayoutAttributes] = [:]
        for piece in pieces(in: place) { known[piece.indexPath.section] = piece }
        guard let piece = known[section] else { return nil }
        let run = run(through: piece, known: &known)
        return run.indexPath.section == section ? run : nil
    }

    /// The run card's item in its section: clear of the index paths the sections' own decorations use.
    static let runItem = 4096

    private static func isPiece(_ attributes: UICollectionViewLayoutAttributes) -> Bool {
        attributes.representedElementCategory == .decorationView && BackdropCards.pieceKinds.contains(attributes.representedElementKind ?? "")
    }

    private func pieces(in rect: CGRect) -> [UICollectionViewLayoutAttributes] {
        (super.layoutAttributesForElements(in: rect) ?? []).filter(Self.isPiece)
    }

    /// The whole run `start` is part of, from its top piece to its foot. Pieces off the screen are not in `known` (the
    /// list asks only for what shows): they are read from the stretch next to the last piece found.
    private func run(through start: UICollectionViewLayoutAttributes, known: inout [Int: UICollectionViewLayoutAttributes]) -> UICollectionViewLayoutAttributes {
        func next(to edge: UICollectionViewLayoutAttributes, above: Bool, known: inout [Int: UICollectionViewLayoutAttributes]) -> UICollectionViewLayoutAttributes? {
            let section = edge.indexPath.section + (above ? -1 : 1)
            if let piece = known[section] { return piece }
            let reach: CGFloat = 1200
            let beside = CGRect(x: edge.frame.minX, y: above ? edge.frame.minY - reach : edge.frame.maxY, width: max(1, edge.frame.width), height: reach)
            for piece in pieces(in: beside) where known[piece.indexPath.section] == nil { known[piece.indexPath.section] = piece }
            return known[section]
        }
        var frame = start.frame, first = start.indexPath.section
        var current = start
        while current.representedElementKind != BackdropCards.topKind, let above = next(to: current, above: true, known: &known),
              above.representedElementKind != BackdropCards.footKind {
            frame = frame.union(above.frame)
            first = above.indexPath.section
            current = above
        }
        current = start
        while current.representedElementKind != BackdropCards.footKind, let below = next(to: current, above: false, known: &known),
              below.representedElementKind != BackdropCards.topKind {
            frame = frame.union(below.frame)
            current = below
        }
        let run = UICollectionViewLayoutAttributes(forDecorationViewOfKind: BackdropCards.runKind, with: IndexPath(item: Self.runItem, section: first))
        run.frame = frame
        run.zIndex = start.zIndex
        return run
    }
}

/// Keeps a sideways-scrolling strip cut at its card's sides: a mask that stays where it is while the strip's content
/// moves under it (a layer's mask moves with what it scrolls).
private final class SidewaysClip: NSObject {
    private static let key = malloc(1)!
    private let mask = CALayer()
    private var watch: NSKeyValueObservation?
    private var sides: (left: CGFloat, right: CGFloat)

    /// `sides`: how far in from the strip's own edges the card's sides are; nil takes the cut off.
    @MainActor static func set(_ sides: (left: CGFloat, right: CGFloat)?, on strip: UIScrollView) {
        let clip = objc_getAssociatedObject(strip, key) as? SidewaysClip
        guard let sides, sides.left > 0 || sides.right > 0 else {
            if clip != nil {
                strip.layer.mask = nil
                objc_setAssociatedObject(strip, key, nil, .OBJC_ASSOCIATION_RETAIN)
            }
            return
        }
        if let clip {
            clip.sides = sides
            clip.fit(strip)
        } else {
            objc_setAssociatedObject(strip, key, SidewaysClip(strip, sides), .OBJC_ASSOCIATION_RETAIN)
        }
    }

    @MainActor private init(_ strip: UIScrollView, _ sides: (left: CGFloat, right: CGFloat)) {
        self.sides = sides
        super.init()
        mask.backgroundColor = UIColor.black.cgColor
        strip.layer.mask = mask
        fit(strip)
        watch = strip.observe(\.bounds) { [weak self] strip, _ in
            MainActor.assumeIsolated { self?.fit(strip) }
        }
    }

    @MainActor private func fit(_ strip: UIScrollView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = CGRect(x: strip.bounds.minX + sides.left, y: strip.bounds.minY - 40,
                            width: max(0, strip.bounds.width - sides.left - sides.right), height: strip.bounds.height + 80)
        CATransaction.commit()
    }
}

/// A joined section's piece of card. In a `BackdropCardLayout` it draws nothing (the run's one card is behind it); in any
/// other layout it is the card's piece itself.
class BackdropCardPieceView: BackdropCardView {
    private weak var layout: BackdropCardLayout?

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if let list = superview as? UICollectionView { layout = list.collectionViewLayout as? BackdropCardLayout }
        surface.isHidden = layout != nil
        layout?.piecesChanged()
    }

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        layout?.piecesChanged()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        layout?.piecesChanged()
    }
}

/// A card joined to the one below: round only at the top.
final class BackdropCardTopView: BackdropCardPieceView {
    override init(frame: CGRect) { super.init(frame: frame); surface.open = .bottom }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// A card joined to the one above: round only at the foot.
final class BackdropCardFootView: BackdropCardPieceView {
    override init(frame: CGRect) { super.init(frame: frame); surface.open = .top }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// A card joined both ways: square.
final class BackdropCardMiddleView: BackdropCardPieceView {
    override init(frame: CGRect) { super.init(frame: frame); surface.open = [.top, .bottom] }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// A row of a list that can stand on soft cards. A swipe moves the whole row, and its words slid out over the picture
/// past the card's edge. While a row swipes, UIKit masks it to the list with a view it moves against the row in step
/// with the slide; on a card that mask's opaque part is narrowed to the card (as `SessionListCell` does for a
/// project's card), so the row slides inside its card. Off cards the mask is left as UIKit made it.
class SoftCardListCell: UICollectionViewListCell {
    private static let cardPiece = 0x48515343

    override var mask: UIView? { didSet { BackdropCards.fit(mask, of: self, tag: Self.cardPiece) } }
}

extension BackdropCards {
    /// Narrows a swiping row's mask to its card, `side` in from the list's edges; puts it back off cards.
    static func fit(_ mask: UIView?, of row: UIView, tag: Int) {
        guard let mask else { return }
        let piece = mask.viewWithTag(tag)
        guard isCarded(row.superview) else {
            if let piece {
                piece.removeFromSuperview()
                mask.backgroundColor = .black
            }
            return
        }
        guard piece == nil else { return }
        let card = UIView(frame: mask.bounds.insetBy(dx: side, dy: 0))
        card.tag = tag
        card.backgroundColor = .black
        card.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mask.backgroundColor = .clear
        mask.addSubview(card)
    }
}

/// A section's card, as a section background.
class BackdropCardView: UICollectionReusableView {
    let surface = SoftCardSurface()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        surface.frame = bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(surface)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// [backdrop-cards] The grouped pages (SwiftUI lists on `hqGroupedPage`, More, table pages). While the picture shows
/// and Soft Cards is on, each section is one soft card from its title's top to its note's foot, `BackdropCards.side`
/// from the page's edges, as the plain lists' sections are; its rows give up iOS's own card (`softRows`), so there is
/// one surface, not a card on a plate. Drawn in the list behind its rows and moved with it; only the sections near the
/// screen get one.
@MainActor final class BackdropPlates: NSObject {
    private weak var list: UIScrollView?
    private let shows: () -> Bool
    private var plates: [SoftCardSurface] = []
    private var watches: [NSKeyValueObservation] = []
    private var scheduled = false
    /// How far the list's start is moved so its first card stands one gap under the bar (`lift`).
    private var lifted: CGFloat = 0
    private var switchWatch: NSObjectProtocol?
    /// Soft cards are drawn just now (the rows are clear on them).
    private(set) var active = false
    /// Supplementary kinds that are not a section's title or note (More's links under its last group).
    private let loose: Set<String>
    private static let key = malloc(1)!
    /// Room under a note's words past the room it comes with.
    static var notePad: CGFloat { rim - slack(.note) }
    /// Room over a title's words past the room it comes with (so it stands as far in as the last row's words do).
    static var titlePad: CGFloat { max(0, rim - slack(.title)) }
    /// The space a list leaves between sections while cards show: `BackdropCards.gap` between two cards, and a
    /// card's `rim` past its rows on each side of it.
    static let sectionSpacing: CGFloat = BackdropCards.gap + 2 * rim
    /// How far a card reaches past its section's rows.
    static let rim: CGFloat = 6

    private init(list: UIScrollView, loose: Set<String>, shows: @escaping () -> Bool) {
        self.list = list
        self.shows = shows
        self.loose = loose
        super.init()
        watches = [
            list.observe(\.contentSize, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.schedule() } },
            // Never measured in the middle of the list's own work (a table asked for its rows while its page was still
            // loading dequeued cells it had not registered yet): each change is drawn on the next turn of the run loop.
            list.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.schedule() } },
            list.observe(\.bounds, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.schedule() } },
        ]
        switchWatch = NotificationCenter.default.addObserver(forName: Backdrop.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
    }

    isolated deinit { switchWatch.map(NotificationCenter.default.removeObserver) }

    /// Attaches (once) to a table or a SwiftUI list; again later only redraws.
    static func attach(to list: UIScrollView, loose: Set<String> = [], shows: @escaping () -> Bool) {
        guard list is UITableView || list is UICollectionView else { return }
        if let existing = objc_getAssociatedObject(list, key) as? BackdropPlates { existing.schedule(); return }
        let plates = BackdropPlates(list: list, loose: loose, shows: shows)
        objc_setAssociatedObject(list, key, plates, .OBJC_ASSOCIATION_RETAIN)
        plates.schedule()
    }

    static func refresh(_ list: UIScrollView?) {
        guard let list, let plates = objc_getAssociatedObject(list, key) as? BackdropPlates else { return }
        plates.schedule()
    }

    /// More room under `list`'s notes, where its rows stand further under a card's top than a plain row does (Files'
    /// folder row, two lines tall).
    static func setNoteExtra(_ extra: CGFloat, for list: UIScrollView) {
        guard let plates = objc_getAssociatedObject(list, key) as? BackdropPlates else { return }
        plates.noteExtra = extra
        plates.schedule()
    }
    private var noteExtra: CGFloat = 0

    /// Whether `list`'s sections stand on soft cards (asked while it lays out, before the cards are drawn).
    static func wanted(for list: UIScrollView) -> Bool {
        guard let plates = objc_getAssociatedObject(list, key) as? BackdropPlates else { return false }
        return plates.shows() && Backdrop.app.cards && !Theme.isDesktop
    }

    /// The room a table leaves over a section's rows on soft cards: the lists' `sectionSpacing`, whatever the section
    /// above ends with (`edges` shares it out).
    static func tableGap(afterNote: Bool) -> CGFloat { sectionSpacing }

    /// Whether `row` (a list or table cell) stands on a soft card just now, so it draws no card of its own.
    static func softRows(for row: UIView) -> Bool {
        var view = row.superview
        for _ in 0..<3 {
            guard let current = view else { return false }
            if current is UICollectionView || current is UITableView {
                return (objc_getAssociatedObject(current, key) as? BackdropPlates)?.active == true
            }
            view = current.superview
        }
        return false
    }

    func schedule() {
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
        guard list.window != nil else { return }   // off screen (still loading): drawn when it shows
        let on = shows() && Backdrop.app.cards && !Theme.isDesktop
        if on != active {
            active = on
            // The rows take iOS's card back, or give it up.
            if let table = list as? UITableView {
                table.visibleCells.forEach { $0.setNeedsUpdateConfiguration() }
                // A table that spaces its sections for the cards (Files) measures them again.
                table.beginUpdates()
                table.endUpdates()
            }
            if let grid = list as? UICollectionView { grid.visibleCells.forEach { $0.setNeedsUpdateConfiguration() } }
        }
        let boxes = on ? sections(of: list, near: list.bounds.insetBy(dx: 0, dy: -600)) : []
        while plates.count < boxes.count {
            let plate = SoftCardSurface()
            plate.layer.zPosition = -100
            list.insertSubview(plate, at: 0)
            plates.append(plate)
        }
        let width = list.bounds.width
        // A table's picture is its background view, which a card must stand on; a SwiftUI list's is behind the list.
        let picture = (list as? UITableView)?.backgroundView
        let edges = Self.edges(of: boxes.map { ($0.first, $0.last) }, noteExtra: noteExtra)
        lift(on ? edges.first?.top : nil, in: list)
        for (index, plate) in plates.enumerated() {
            guard index < boxes.count else { plate.isHidden = true; continue }
            let section = boxes[index]
            plate.isHidden = false
            if let picture, plate.layer.zPosition != picture.layer.zPosition {
                plate.layer.zPosition = picture.layer.zPosition
                list.insertSubview(plate, aboveSubview: picture)
            }
            let all = [section.cards, section.title, section.note].compactMap { $0 }.reduce(CGRect.null) { $0.union($1) }
            let top = edges[index].top, bottom = edges[index].bottom
            // `side` from the list's edges, as the plain lists' cards. A table's section is as wide as the table.
            let edge = section.cards ?? all
            let inset = edge.minX > 1
            // (An iPad's rows stand 20 pt in, an iPhone's 16: the card is `side` from the edges on both, as every
            // list's cards. Rows set far in, a column in the middle of a wide page, keep a card that hugs them.)
            let hugs = edge.minX - Self.rim > BackdropCards.side + Self.rim
            let left = inset && hugs ? max(0, edge.minX - Self.rim) : BackdropCards.side
            let right = inset && hugs ? min(width, edge.maxX + Self.rim) : width - BackdropCards.side
            let frame = CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
            if plate.frame != frame { plate.frame = frame }
            if plate.superview !== list {
                if let picture { list.insertSubview(plate, aboveSubview: picture) } else { list.insertSubview(plate, at: 0) }
            }
        }
    }

    /// [soft-cards] Owner 2026-11-13: "Stuff is just not consistent." Each page's first card began where that page's
    /// first row happened to (8 to 40 pt under the bar: Settings, Files, Bot Profiles, Passwords all differed), because
    /// every kind of page keeps its own room over its first section. On Soft Cards the list's start is moved so the
    /// first card stands one gap under the bar (or whatever is over the list), as the cards stand from each other.
    /// `top`: the first card's top in the list, or nil with no cards. Only while the list's start is among the
    /// sections read, and never under a table's own header view with something in it.
    private func lift(_ top: CGFloat?, in list: UIScrollView) {
        var wanted: CGFloat = lifted
        if let top {
            let header = (list as? UITableView)?.tableHeaderView
            let plain = header == nil || (header?.subviews.isEmpty == true && (header?.frame.height ?? 0) <= 44)
            if list.bounds.minY - 600 <= 0 { wanted = plain ? BackdropCards.gap - top : 0 }
        } else {
            wanted = 0
        }
        guard abs(wanted - lifted) > 0.5 else { return }
        let before = list.adjustedContentInset.top
        let resting = abs(list.contentOffset.y + before) < 1
        list.contentInset.top += wanted - lifted
        lifted = wanted
        if resting { list.contentOffset.y = -list.adjustedContentInset.top }
    }

    /// One section near the screen: its cards, and its title and note when it has them.
    private struct Section {
        var cards: CGRect?; var title: CGRect?; var note: CGRect?
        /// What it starts with and where; what it ends with and where.
        var first: (End, CGFloat) { title.map { (.title, $0.minY) } ?? cards.map { (.rows, $0.minY) } ?? (.note, note?.minY ?? 0) }
        var last: (End, CGFloat) { note.map { (.note, $0.maxY) } ?? cards.map { (.rows, $0.maxY) } ?? (.title, title?.maxY ?? 0) }
    }

    /// What stands at a card's top or foot.
    enum End { case rows, title, note }

    /// How much more room an end's own frame holds past its words than a row's does (a title stands lower in its
    /// frame than a row's words; a note's words end closer to its frame's foot). Measured at UI Scale 85, 100, 115 %
    /// and at the iPhone's XXL text size.
    static func slack(_ end: End) -> CGFloat {
        switch end {
        case .rows: 0
        // (UI Scale and the iPhone's own text size each move a title in its frame by their own amount.)
        case .title: 3 + BackdropCards.grown(20) + 6 * (BackdropCards.textSize - 1)
        case .note: -3 + BackdropCards.grown(12)
        }
    }

    /// Where each section's card starts and ends. Owner 2026-11-13: "Stuff is just not consistent." The cards stood 13,
    /// 16 or 19 pt apart on one page, by whether one ended in a note or the next began with a title (each end kept its
    /// own fixed room, and the list's spacing is one number). Now two neighbours always stand `BackdropCards.gap`
    /// apart, and what is left of the space between them is shared so the words over the gap and the words under it
    /// stand equally far from their cards' edges. The page's first and last cards mirror their other end.
    /// `sections`: each one's first and last frame edge and what stands there, top to bottom.
    static func edges(of sections: [(first: (End, CGFloat), last: (End, CGFloat))], noteExtra: CGFloat = 0) -> [(top: CGFloat, bottom: CGFloat)] {
        func plain(_ end: End) -> CGFloat { max(0, rim - slack(end)) }
        // Alone, each end keeps the room that puts its words a row's distance in.
        var reach = sections.map { (top: plain($0.first.0), bottom: plain($0.last.0) + ($0.last.0 == .note ? noteExtra : 0)) }
        var shared = Array(repeating: (top: false, bottom: false), count: sections.count)
        for index in sections.indices.dropLast() {
            let above = sections[index].last, below = sections[index + 1].first
            let extra = above.0 == .note ? noteExtra : 0
            let room = below.1 - above.1 - BackdropCards.gap - extra
            guard room >= 4 else { continue }   // too close to part them: each keeps its own
            let bottom = min(max((room + slack(below.0) - slack(above.0)) / 2, 1), room - 1)
            reach[index].bottom = bottom + extra
            reach[index + 1].top = room - bottom
            shared[index].bottom = true
            shared[index + 1].top = true
        }
        // An end with no neighbour stands as far from its words as the card's other end does.
        for index in sections.indices {
            let first = sections[index].first.0, last = sections[index].last.0
            let extra = last == .note ? noteExtra : 0
            if !shared[index].top, shared[index].bottom { reach[index].top = max(0, reach[index].bottom - extra + slack(last) - slack(first)) }
            if !shared[index].bottom, shared[index].top { reach[index].bottom = max(0, reach[index].top + slack(first) - slack(last)) + extra }
        }
        // A card between two different neighbours (rows over it, a title under it) gets a little more at one end than
        // the other. Past `lean` the longer end gives the rest back, and that gap is the wider for it (it only comes
        // to that at a large UI Scale, where a title's own room grows).
        for index in sections.indices where shared[index].top && shared[index].bottom {
            let first = sections[index].first.0, last = sections[index].last.0
            let extra = last == .note ? noteExtra : 0
            let over = (reach[index].top + slack(first)) - (reach[index].bottom - extra + slack(last))
            guard abs(over) > lean else { continue }
            if over > 0 { reach[index].top = max(0, reach[index].top - (over - lean)) }
            else { reach[index].bottom = max(extra, reach[index].bottom - (-over - lean)) }
        }
        return sections.indices.map { (top: sections[$0].first.1 - reach[$0].top, bottom: sections[$0].last.1 + reach[$0].bottom) }
    }
    /// How much further one end of a card may stand from its words than the other.
    static let lean: CGFloat = 1.5

    /// Each section near the screen, from its title's top to its note's foot.
    private func sections(of list: UIScrollView, near rect: CGRect) -> [Section] {
        var found: [Int: Section] = [:]
        /// A title or note with words in it (an empty one is only the list's spacing).
        func words(_ frame: CGRect) -> Bool { frame.height > 24 }   // a blank one is 18–20 pt, one line of words 30–40
        if let table = list as? UITableView {
            for index in 0..<table.numberOfSections where table.rect(forSection: index).intersects(rect) {
                // The section's rect and its title's and note's (not each row's: that has the table make its cells).
                var section = Section()
                let whole = table.rect(forSection: index), head = table.rectForHeader(inSection: index), foot = table.rectForFooter(inSection: index)
                if table.headerView(forSection: index) != nil, words(head) { section.title = head }
                if table.footerView(forSection: index) != nil, words(foot) { section.note = foot }
                let rowsTop = head.height > 0 ? head.maxY : whole.minY, rowsBottom = foot.height > 0 ? foot.minY : whole.maxY
                if table.numberOfRows(inSection: index) > 0, rowsBottom > rowsTop {
                    section.cards = CGRect(x: whole.minX, y: rowsTop, width: whole.width, height: rowsBottom - rowsTop)
                }
                if section.cards != nil || section.title != nil || section.note != nil { found[index] = section }
            }
        } else if let grid = list as? UICollectionView {
            let items = (grid.collectionViewLayout.layoutAttributesForElements(in: rect) ?? [])
                .filter { $0.representedElementCategory != .decorationView && !$0.isHidden && $0.frame.height > 0.5 }
            for item in items where item.representedElementCategory == .cell {
                found[item.indexPath.section, default: Section()].cards = found[item.indexPath.section]?.cards.map { $0.union(item.frame) } ?? item.frame
            }
            for item in items where item.representedElementCategory == .supplementaryView && words(item.frame)
                && !(item.representedElementKind.map(loose.contains) ?? false) {
                var section = found[item.indexPath.section, default: Section()]
                // Above the section's cards it is the title; below them, the note (by place: kinds differ by list).
                if let cards = section.cards, item.frame.midY > cards.midY { section.note = section.note.map { $0.union(item.frame) } ?? item.frame }
                else { section.title = section.title.map { $0.union(item.frame) } ?? item.frame }
                found[item.indexPath.section] = section
            }
        }
        return found.keys.sorted().compactMap { found[$0] }
    }
}

// MARK: - Loose lines

/// [backdrop-cards] A line that stands on the page by itself (a count under a list, an empty or slow note): with Soft
/// Cards on and the app's picture showing, a soft backing of the cards' colour, a capsule for one line, a card's
/// corners for a note. Otherwise nothing.
private struct BackdropLineBacking: ViewModifier {
    let capsule: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if Backdrop.app.cards && Backdrop.app.shows {
            content
                .padding(.horizontal, capsule ? 12 : 16)
                .padding(.vertical, capsule ? 5 : 14)
                .background(SoftCardBackground(capsule: capsule))
        } else {
            content
        }
    }
}

extension View {
    /// [backdrop-cards] See `BackdropLineBacking`.
    func hqPictureBacking(capsule: Bool = false) -> some View { modifier(BackdropLineBacking(capsule: capsule)) }
}

// MARK: - Empty and error states

/// [backdrop-cards] A page's empty, error or update state (iOS's `UIContentUnavailableConfiguration`) stood straight on
/// the picture: "No Artifacts in Recent Chats", Tasks' "Update the Add-on". Wrapped in this, it draws the same, and with
/// Soft Cards on and the page's picture showing a soft card stands behind its picture, words and buttons. Use it where a
/// page hands the state over (`contentUnavailableConfiguration`, a list's background, a state cell).
struct BackdropStateConfiguration: UIContentConfiguration {
    var inner: UIContentUnavailableConfiguration

    func makeContentView() -> any UIView & UIContentView { BackdropStateView(configuration: self) }
    func updated(for state: any UIConfigurationState) -> BackdropStateConfiguration {
        var copy = self
        copy.inner = inner.updated(for: state)
        return copy
    }
}

enum BackdropState {
    /// `config` wrapped, when it is iOS's state; anything else (nil, a hosting configuration) as it is.
    static func wrap(_ config: (any UIContentConfiguration)?) -> (any UIContentConfiguration)? {
        guard let state = config as? UIContentUnavailableConfiguration else { return config }
        return BackdropStateConfiguration(inner: state)
    }

    /// The state inside, for code that reads it back (the iPad's and the Mac's placeholder beside the list).
    static func unwrap(_ config: (any UIContentConfiguration)?) -> (any UIContentConfiguration)? {
        (config as? BackdropStateConfiguration)?.inner ?? config
    }
}

final class BackdropStateView: UIView, UIContentView {
    private let state: UIContentUnavailableView
    private let card = SoftCardSurface()
    private var watches: [NSObjectProtocol] = []

    var configuration: any UIContentConfiguration {
        didSet {
            guard let wrapped = configuration as? BackdropStateConfiguration else { return }
            state.configuration = wrapped.inner
            setNeedsLayout()
        }
    }

    init(configuration: BackdropStateConfiguration) {
        self.configuration = configuration
        state = UIContentUnavailableView(configuration: configuration.inner)
        super.init(frame: .zero)
        card.isHidden = true
        for view in [card, state] as [UIView] {
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(view)
        }
        card.autoresizingMask = []
        for name in [Backdrop.didChange, Backdrop.pictureReady] {
            watches.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setNeedsLayout() }
            })
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    isolated deinit { watches.forEach(NotificationCenter.default.removeObserver) }

    func supports(_ configuration: any UIContentConfiguration) -> Bool { configuration is BackdropStateConfiguration }

    override func systemLayoutSizeFitting(_ target: CGSize, withHorizontalFittingPriority h: UILayoutPriority,
                                          verticalFittingPriority v: UILayoutPriority) -> CGSize {
        state.systemLayoutSizeFitting(target, withHorizontalFittingPriority: h, verticalFittingPriority: v)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        state.frame = bounds
        // The page's own picture (`PageBackdrop`): a state on a page without one, or in a sheet, keeps the plain look.
        let owner = sequence(first: self as UIResponder, next: \.next).first { $0 is UIViewController } as? UIViewController
        guard window != nil, BackdropCards.on(owner) else { card.isHidden = true; return }
        state.layoutIfNeeded()
        let box = Self.content(in: state, to: self)
        guard !box.isNull, box.width > 1 else { card.isHidden = true; return }
        card.isHidden = false
        card.frame = box.insetBy(dx: -20, dy: -16).intersection(bounds.insetBy(dx: BackdropCards.side, dy: 0))
    }

    /// Where the state's picture, words and buttons are.
    private static func content(in view: UIView, to space: UIView) -> CGRect {
        var box = CGRect.null
        for child in view.subviews where !child.isHidden && child.alpha > 0.01 {
            let drawn: Bool = switch child {
            case let label as UILabel: !(label.text ?? label.attributedText?.string ?? "").isEmpty
            case let image as UIImageView: image.image != nil
            case is UIButton, is UIActivityIndicatorView: true
            default: false
            }
            if drawn, child.bounds.width > 0.5 { box = box.union(child.convert(child.bounds, to: space)) }
            else { box = box.union(content(in: child, to: space)) }
        }
        return box
    }
}
