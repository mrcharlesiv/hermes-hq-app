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

    private static func kind(_ join: Join) -> String { join.isEmpty ? kind : kind + ".\(join.rawValue)" }

    static func register(in layout: UICollectionViewLayout) {
        layout.register(BackdropCardView.self, forDecorationViewOfKind: kind)
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
    static func card(_ section: NSCollectionLayoutSection, on: Bool, header: Bool = false, keepWidth: Bool = false, join: Join = []) {
        guard on else { return }
        var insets = section.contentInsets
        if !keepWidth {
            insets.leading += side
            insets.trailing += side
        }
        let top = join.contains(.above) || header ? 0 : pad, bottom = join.contains(.below) ? 0 : pad
        insets.top += top
        insets.bottom += join.contains(.below) ? 0 : pad + gap
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

/// A card joined to the one below: round only at the top.
final class BackdropCardTopView: BackdropCardView {
    override init(frame: CGRect) { super.init(frame: frame); surface.open = .bottom }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// A card joined to the one above: round only at the foot.
final class BackdropCardFootView: BackdropCardView {
    override init(frame: CGRect) { super.init(frame: frame); surface.open = .top }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// A card joined both ways: square.
final class BackdropCardMiddleView: BackdropCardView {
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
    private var switchWatch: NSObjectProtocol?
    /// Soft cards are drawn just now (the rows are clear on them).
    private(set) var active = false
    /// Supplementary kinds that are not a section's title or note (More's links under its last group).
    private let loose: Set<String>
    private static let key = malloc(1)!
    /// Room under a note's words past the room it comes with.
    static let notePad: CGFloat = 6
    /// The space between sections while cards show (iOS's compact spacing left them touching).
    static let sectionSpacing: CGFloat = 28
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
            if let table = list as? UITableView { table.visibleCells.forEach { $0.setNeedsUpdateConfiguration() } }
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
        for (index, plate) in plates.enumerated() {
            guard index < boxes.count else { plate.isHidden = true; continue }
            let section = boxes[index]
            plate.isHidden = false
            if let picture, plate.layer.zPosition != picture.layer.zPosition {
                plate.layer.zPosition = picture.layer.zPosition
                list.insertSubview(plate, aboveSubview: picture)
            }
            // Each edge is set by what is there: a title or a note keeps the room it comes with and `notePad` more
            // under a note (owner 2026-11-12: a note sat tight on the foot); bare rows get `rim` all round.
            let all = [section.cards, section.title, section.note].compactMap { $0 }.reduce(CGRect.null) { $0.union($1) }
            let top = section.title?.minY ?? ((section.cards?.minY ?? all.minY) - Self.rim)
            let bottom = section.note.map { $0.maxY + Self.notePad } ?? ((section.cards?.maxY ?? all.maxY) + Self.rim)
            // `rim` past the section's rows (10 pt from an iPhone's edges, as the plain lists' cards; on an iPad, whose
            // rows stand further in, still just round them). A table's section is as wide as the table: `side` in.
            let edge = section.cards ?? all
            let inset = edge.minX > 1
            let left = inset ? max(0, edge.minX - Self.rim) : BackdropCards.side
            let right = inset ? min(width, edge.maxX + Self.rim) : width - BackdropCards.side
            let frame = CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
            if plate.frame != frame { plate.frame = frame }
            if plate.superview !== list {
                if let picture { list.insertSubview(plate, aboveSubview: picture) } else { list.insertSubview(plate, at: 0) }
            }
        }
    }

    /// One section near the screen: its cards, and its title and note when it has them.
    private struct Section { var cards: CGRect?; var title: CGRect?; var note: CGRect? }

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
