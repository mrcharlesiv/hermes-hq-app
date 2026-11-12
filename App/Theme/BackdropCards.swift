// [backdrop-cards] Owner 2026-11-11: "Some things need a background of sorts behind them when you use a wallpaper for
// the app." Bots, Sessions, Jobs and the other plain lists put their rows, names, times and section titles straight on
// the picture, where a busy one (the doodles) ran through the words. While a page's picture shows, each section of its
// list (its title and its rows) stands on one soft card: the page's card colour over a light blur, the corners of the
// grouped pages' cards, inset 10 pt from the edges, so the list reads as the grouped pages (Gateway, Settings) do on
// the same picture. With no picture, in a sheet, or in the Desktop Look (which draws no picture) nothing changes.
// Owner 2026-11-12: a switch, off until turned on: Theme › Backgrounds › App Background › Soft Cards
// (`Backdrop.cards`, `hqn.appBackground.cards`).

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
        layout.register(BackdropPlateView.self, forDecorationViewOfKind: plateKind)
    }

    static let plateKind = "hqn.backdropPlate"

    /// [backdrop-cards] A section that draws its own card (Kanban's groups): a plate behind its title and card, as the
    /// grouped pages' (`BackdropPlates`), `BackdropPlates.rim` past the card. `cards` is the card's own inset in the
    /// section; call before the section's card is made, as a gap is added under it.
    static func plate(_ section: NSCollectionLayoutSection, on: Bool) {
        guard on else { return }
        section.contentInsets.bottom += gap
        let insets = section.contentInsets, rim = BackdropPlates.rim
        let plate = NSCollectionLayoutDecorationItem.background(elementKind: plateKind)
        // At most `side` from the page's edges, as every other page's cards and plates (Kanban's card is 20 pt in).
        plate.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: min(side, max(0, insets.leading - rim)),
                                                      bottom: max(0, insets.bottom - rim), trailing: min(side, max(0, insets.trailing - rim)))
        plate.zIndex = -2
        section.decorationItems.append(plate)
    }

    /// Whether `controller`'s lists draw cards just now: its picture shows (`PageBackdrop`).
    static func on(_ controller: UIViewController?) -> Bool {
        !Theme.isDesktop && Backdrop.app.cards && PageBackdrop.showsPicture(on: controller)
    }

    /// Puts `section` on a card when `on`: its rows move in `side` from the edges, and the card hugs its rows and header.
    /// `keepWidth`: a section that lays out its own width (the Bots faces, centred in three columns) keeps it; the card
    /// stands `side` from the page's edges behind it. `join`: the card runs on into the section above or below.
    static func card(_ section: NSCollectionLayoutSection, on: Bool, keepWidth: Bool = false, join: Join = []) {
        guard on else { return }
        var insets = section.contentInsets
        if !keepWidth {
            insets.leading += side
            insets.trailing += side
        }
        let top = join.contains(.above) ? 0 : pad, bottom = join.contains(.below) ? 0 : pad
        insets.top += top
        insets.bottom += join.contains(.below) ? 0 : pad + gap
        section.contentInsets = insets
        let card = NSCollectionLayoutDecorationItem.background(elementKind: kind(join))
        card.contentInsets = NSDirectionalEdgeInsets(top: join.contains(.above) ? 0 : max(0, insets.top - top),
                                                     leading: keepWidth ? side : insets.leading,
                                                     bottom: join.contains(.below) ? 0 : max(0, insets.bottom - bottom),
                                                     trailing: keepWidth ? side : insets.trailing)
        card.zIndex = -1
        section.decorationItems.append(card)
    }
}

/// The grouped pages' lighter plate, as a section background (`BackdropCards.plate`).
final class BackdropPlateView: BackdropCardView {
    override init(frame: CGRect) { super.init(frame: frame); cornerRadius = 26; tintAlpha = 0.5 }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// A card joined to the one below: round only at the top.
final class BackdropCardTopView: BackdropCardView {
    override init(frame: CGRect) { super.init(frame: frame); layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner] }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// A card joined to the one above: round only at the foot.
final class BackdropCardFootView: BackdropCardView {
    override init(frame: CGRect) { super.init(frame: frame); layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// A card joined both ways: square.
final class BackdropCardMiddleView: BackdropCardView {
    override init(frame: CGRect) { super.init(frame: frame); layer.maskedCorners = [] }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// The card: the page's card colour, a little see-through, over a light blur of the picture.
class BackdropCardView: UICollectionReusableView {
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let tint = UIView()
    var cornerRadius: CGFloat = 22 { didSet { layer.cornerRadius = cornerRadius } }
    /// How much of the card colour lies over the blur (a grouped page's plate is lighter: its rows' cards stand out on it).
    var tintAlpha: CGFloat = 0.78 { didSet { tint.backgroundColor = HQPalette.card.withAlphaComponent(tintAlpha) } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        clipsToBounds = true
        for view in [blur, tint] as [UIView] {
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(view)
        }
        tint.backgroundColor = HQPalette.card.withAlphaComponent(tintAlpha)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// [backdrop-cards] The grouped pages (SwiftUI lists on `hqGroupedPage`, and table pages): their rows already stand on
/// cards, but a section's title over them and its note under them sat on the picture. While the picture shows, each
/// section (title, card and note) stands on a frosted plate `BackdropCards.side` from the page's edges, the same
/// backing the plain lists' sections get, so every page reads alike on a picture. Drawn in the list behind its rows and
/// moved with it; only the sections near the screen get one.
@MainActor final class BackdropPlates: NSObject {
    private weak var list: UIScrollView?
    private let shows: () -> Bool
    private var plates: [BackdropCardView] = []
    private var watches: [NSKeyValueObservation] = []
    private var scheduled = false
    private var switchWatch: NSObjectProtocol?
    private static let key = malloc(1)!
    /// Room under a note's words past the room it comes with.
    static let notePad: CGFloat = 6
    /// The space between sections while plates show (iOS's compact spacing left the plates touching).
    static let sectionSpacing: CGFloat = 28
    /// How far a plate reaches past its section's cards at the sides.
    static let rim: CGFloat = 6

    private init(list: UIScrollView, shows: @escaping () -> Bool) {
        self.list = list
        self.shows = shows
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
    static func attach(to list: UIScrollView, shows: @escaping () -> Bool) {
        guard list is UITableView || list is UICollectionView else { return }
        if let existing = objc_getAssociatedObject(list, key) as? BackdropPlates { existing.schedule(); return }
        let plates = BackdropPlates(list: list, shows: shows)
        objc_setAssociatedObject(list, key, plates, .OBJC_ASSOCIATION_RETAIN)
        plates.schedule()
    }

    static func refresh(_ list: UIScrollView?) {
        guard let list, let plates = objc_getAssociatedObject(list, key) as? BackdropPlates else { return }
        plates.schedule()
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
        let boxes = shows() && Backdrop.app.cards && !Theme.isDesktop ? sections(of: list, near: list.bounds.insetBy(dx: 0, dy: -600)) : []
        while plates.count < boxes.count {
            let plate = BackdropCardView(frame: .zero)
            plate.layer.zPosition = -100
            plate.cornerRadius = 26
            plate.tintAlpha = 0.5
            list.insertSubview(plate, at: 0)
            plates.append(plate)
        }
        let width = list.bounds.width
        // A table's picture is its background view, which a plate must stand on; a SwiftUI list's is behind the list.
        let picture = (list as? UITableView)?.backgroundView
        for (index, plate) in plates.enumerated() {
            guard index < boxes.count else { plate.isHidden = true; continue }
            let section = boxes[index]
            plate.isHidden = false
            if let picture, plate.layer.zPosition != picture.layer.zPosition {
                plate.layer.zPosition = picture.layer.zPosition
                list.insertSubview(plate, aboveSubview: picture)
            }
            // Owner 2026-11-12: a note sat tight on the plate's foot. Each edge is set by what is there: a title or a
            // note keeps the room it comes with and `notePad` more under a note; bare cards get `rim` all round.
            let all = [section.cards, section.title, section.note].compactMap { $0 }.reduce(CGRect.null) { $0.union($1) }
            let top = section.title?.minY ?? ((section.cards?.minY ?? all.minY) - Self.rim)
            let bottom = section.note.map { $0.maxY + Self.notePad } ?? ((section.cards?.maxY ?? all.maxY) + Self.rim)
            // `rim` past the section's cards (10 pt from an iPhone's edges, as the plain lists' cards; on an iPad, whose
            // cards stand further in, still just round them). A table's section is as wide as the table: `side` in.
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
        func words(_ frame: CGRect) -> Bool { frame.height > 12 }
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
            for item in items where item.representedElementCategory == .supplementaryView && words(item.frame) {
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
                .padding(.vertical, capsule ? 5 : 12)
                .background {
                    let fill = Color(uiColor: HQPalette.card).opacity(0.78)
                    if capsule { Capsule().fill(.ultraThinMaterial).overlay(Capsule().fill(fill)) }
                    else { RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(fill)) }
                }
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
    private let card = BackdropCardView(frame: .zero)
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
