// [project-cards] Group By Project draws each project as a card (owner, 2026-10-31: "A + B, the card with the line on
// the inside"). The card is drawn in slices, one per list item: the header is its top, each chat and Show More a middle,
// New Chat its foot. Only an open project has its card (owner: "only have a shadow when selected"); a closed one is a
// row on the page, as Pinned's, until a dragged chat is held over it. A line runs from the project's folder down through each chat's face to New
// Chat, so every bot's chat reads as part of the project. Rows are Pinned's size (owner: "everything is too big").
//
// Pictures: artifacts/project-groups/mock3.html. The cells draw their slice as a background (so a press can fill it);
// the header and New Chat, which are never pressed as cells, draw theirs in SwiftUI (the header's a UIKit piece in it, for
// its fade). All share `ProjectCard`'s numbers.

import SwiftUI
import UIKit

/// Where a piece of a project's card sits.
enum ProjectCardSlice {
    /// A closed project with a dragged chat held over it: its header is the whole card.
    case whole
    /// An open project's header.
    case top
    /// A chat or Show More.
    case middle
    /// New Chat, the card's last row.
    case bottom

    /// A chat, Show More and New Chat are cells the layout already sets in to the card's edges (`ProjectCard.inset`);
    /// the header is the list's full width.
    var inCell: Bool { self == .middle || self == .bottom }
}

@MainActor enum ProjectCard {
    /// The card stands this far in from the list's edges.
    static let inset: CGFloat = 12
    /// Space above and below each card (the "Projects" caption has its own).
    static let gap: CGFloat = 12
    /// Space between two closed projects: none, they are rows on the page 44 pt apart, as Pinned's.
    static let rowGap: CGFloat = 0
    static var radius: CGFloat { Theme.isDesktop ? 10 : 22 }
    /// The face column: 40 pt from the list's edge plus 20 pt in, as Pinned's rows, so faces line up with Pinned's.
    static var column: CGFloat { Theme.isDesktop ? DesktopRows.face : Density.ios(40, 32) }   // [density] the chat rows' column too
    static var columnGap: CGFloat { Theme.isDesktop ? DesktopRows.gap : Density.ios(12, 10) }
    static let lead: CGFloat = 20
    /// The line's centre: the middle of the face column.
    static var lineX: CGFloat { lead + column / 2 }
    static let lineWidth: CGFloat = 2
    /// The text's trailing edge inside the card.
    static let trailing: CGFloat = 26
    /// The same edges in the card's own cells (a chat, Show More, New Chat), which start at the card's edge, so a swipe
    /// moves a chat inside the card and its buttons sit inside it.
    static var cellLead: CGFloat { lead - inset }
    static var cellTrailing: CGFloat { trailing - inset }
    static var cellLineX: CGFloat { lineX - inset }
    /// A closed project's trailing edge on the page: a chat row's, so its count stands under Pinned's times.
    static let pageTrailing: CGFloat = 20
    /// A chat's face, and the space above and below it in its row (a one-line row is 44 pt, as Pinned's).
    static var face: CGFloat { Theme.isDesktop ? HQFont.scaled(22) : Density.ios(28, 22) }
    static var rowPad: CGFloat { Theme.isDesktop ? 7 : Density.ios(8, 5) }
    /// Where a row's face (and its node on the line) is centred, from the row's top.
    static var nodeY: CGFloat { rowPad + face / 2 }
    /// An open card's header and New Chat stand this much further in from the card's rounded ends.
    static let cardTop: CGFloat = 4
    /// The line stops this far short of a face, so it reads as passing behind it.
    static let lineClearance: CGFloat = 3

    static var fill: UIColor { HQPalette.groupedCard }
    /// The folder's box on the card: the page colour in light, a raised grey in dark.
    static let box: UIColor = {
        let raised = HQPalette.fill3, page = HQPalette.page     // read here: the provider resolves off the main thread
        return UIColor { @Sendable traits in
            traits.userInterfaceStyle == .dark ? raised.resolvedColor(with: traits) : page.resolvedColor(with: traits)
        }
    }()
    /// The folder's box on the page (a closed project): a small piece of card.
    static var boxOnPage: UIColor { fill }
    static var line: UIColor { HQPalette.separator }
    /// The Desktop Look outlines its cards (it has no glass and no shadows); the iOS look's card is fill alone.
    static var edge: UIColor? { Theme.isDesktop ? HQPalette.stroke : nil }
    static let edgeWidth: CGFloat = 1

    /// The piece of card behind a cell: the card's fill (the press's while pressed), its corners where the slice has them.
    /// `edged` false: a chat over `ProjectCardUnderRow`, which draws the card's edges; the chat's piece stops short of
    /// them, so a swipe doesn't slide a copy of the edge across the card.
    /// `line`: the project's line through the piece (a chat's, with its gap round the face).
    static func background(_ slice: ProjectCardSlice, _ state: UICellConfigurationState, edged: Bool = true,
                           line: ProjectCardSliceView.Line = .none) -> UIBackgroundConfiguration {
        var background = UIBackgroundConfiguration.clear()
        let view = ProjectCardSliceView(slice: slice)
        view.edged = edged
        view.line = line
        var pressed = state.isHighlighted || state.isSelected
        #if targetEnvironment(macCatalyst)
        if DeviceWord.isMac, let mark = MacSelection.fill(selected: state.isSelected, pressed: state.isHighlighted, in: .list) {
            view.mark = mark
            pressed = false
        }
        #endif
        view.fillColor = pressed ? HQPalette.cellPressed : fill
        background.customView = view
        return background
    }

    /// The rect the card's rounded box is drawn in for a slice of `bounds`: past the slice's open ends, so only the
    /// corners the slice has show (the rest is clipped).
    static func box(for slice: ProjectCardSlice, in bounds: CGRect) -> CGRect {
        let r = radius * 2
        var box = bounds.insetBy(dx: slice.inCell ? 0 : inset, dy: 0)
        switch slice {
        case .whole: break
        case .top: box.size.height += r
        case .middle: box.origin.y -= r; box.size.height += r * 2
        case .bottom: box.origin.y -= r; box.size.height += r
        }
        return box
    }
}

/// A cell's piece of card (UIKit, so the cell's press fills it).
final class ProjectCardSliceView: UIView {
    var fillColor: UIColor = ProjectCard.fill { didSet { setNeedsLayout() } }
    /// [mac] The Mac's selection over the card.
    var mark: UIColor? { didSet { setNeedsLayout() } }
    /// Draws the card's edges (the Desktop Look's); without them it stands clear of where they go.
    var edged = true { didSet { setNeedsLayout() } }
    var slice: ProjectCardSlice { didSet { if slice != oldValue { setNeedsLayout() } } }
    /// [card-line-swipe] The project's line through a chat's own piece, at `ProjectCard.cellLineX`, with a gap round its
    /// face (`node`, from the top, `clear` each way). The piece hides while the chat slides, and the line with it (owner
    /// 2026-11-04: the lines above and below went with the row; "The line should disappear when sliding a session").
    enum Line: Equatable { case none, node(y: CGFloat, clear: CGFloat) }
    var line: Line = .none { didSet { if line != oldValue { setNeedsLayout() } } }
    private let fillLayer = CAShapeLayer()
    private let markLayer = CAShapeLayer()
    private let edgeLayer = CAShapeLayer()
    private let lineLayer = CAShapeLayer()

    init(slice: ProjectCardSlice) {
        self.slice = slice
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        clipsToBounds = true
        layer.addSublayer(fillLayer)
        layer.addSublayer(markLayer)
        layer.addSublayer(edgeLayer)
        layer.addSublayer(lineLayer)
        edgeLayer.fillColor = nil
        edgeLayer.lineWidth = ProjectCard.edgeWidth
        lineLayer.fillColor = nil
        lineLayer.lineWidth = ProjectCard.lineWidth
        lineLayer.lineCap = .butt
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: ProjectCardSliceView, _) in view.setNeedsLayout() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let edge = ProjectCard.edge
        let box = ProjectCard.box(for: slice, in: bounds).insetBy(dx: edge != nil && !edged ? ProjectCard.edgeWidth : 0, dy: 0)
        let radius = ProjectCard.radius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.path = UIBezierPath(roundedRect: box, cornerRadius: radius).cgPath
        fillLayer.fillColor = fillColor.resolvedColor(with: traitCollection).cgColor
        markLayer.path = mark == nil ? nil : UIBezierPath(roundedRect: box, cornerRadius: radius).cgPath
        markLayer.fillColor = mark?.resolvedColor(with: traitCollection).cgColor
        if let edge, edged {
            edgeLayer.path = UIBezierPath(roundedRect: box.insetBy(dx: ProjectCard.edgeWidth / 2, dy: ProjectCard.edgeWidth / 2), cornerRadius: radius).cgPath
            edgeLayer.strokeColor = edge.resolvedColor(with: traitCollection).cgColor
        } else {
            edgeLayer.path = nil
        }
        lineLayer.path = linePath()
        lineLayer.strokeColor = ProjectCard.line.resolvedColor(with: traitCollection).cgColor
        CATransaction.commit()
    }

    /// As `ProjectLine` draws it.
    private func linePath() -> CGPath? {
        let x = ProjectCard.cellLineX, end = bounds.height
        let path = UIBezierPath()
        switch line {
        case .none: return nil
        case .node(let y, let clear):
            if y - clear > 0 { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: y - clear)) }
            if end > y + clear { path.move(to: CGPoint(x: x, y: y + clear)); path.addLine(to: CGPoint(x: x, y: end)) }
        }
        return path.cgPath
    }
}

// MARK: - Swipes inside a card

/// The Sessions list's layout, with a piece of card under each chat in an open project. A swipe moves the whole cell,
/// its own piece of card included, and lays its buttons on whatever is under it (owner 2026-11-01: "Sliding session
/// over moves the background with it"). This piece stays, so the card does.
final class SessionsListLayout: UICollectionViewCompositionalLayout {
    static let cardUnderRow = "sessions.cardUnderRow"
    /// Whether the item at a path is a chat in an open project's card.
    var cardRow: (IndexPath) -> Bool = { _ in false }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let all = super.layoutAttributesForElements(in: rect) else { return nil }
        return all + all.compactMap { $0.representedElementCategory == .cell && cardRow($0.indexPath) ? under($0) : nil }
    }

    override func layoutAttributesForDecorationView(ofKind kind: String, at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard kind == Self.cardUnderRow else { return super.layoutAttributesForDecorationView(ofKind: kind, at: indexPath) }
        return layoutAttributesForItem(at: indexPath).map(under)
    }

    private func under(_ item: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let under = UICollectionViewLayoutAttributes(forDecorationViewOfKind: Self.cardUnderRow, with: item.indexPath)
        under.frame = item.frame
        under.zIndex = item.zIndex - 10
        under.alpha = item.alpha
        under.isHidden = item.isHidden
        return under
    }

    // MARK: [project-unfold] A group opening or closing

    /// A group a header tap opens or closes (owner, 2026-11-02: "smoothly roll out … not a jarring jump"). Its rows
    /// travel as one piece: opening, from under the header's foot down to their places; closing, back up under it. They
    /// don't fade (the list masks each at the header's foot), so they read as one sheet unrolling from the header. Set
    /// only while the list applies the change.
    struct Unfold {
        /// The group's section after the change, and before it.
        var section: Int
        var oldSection: Int
        var opening: Bool
        /// Opening: how many rows it draws now.
        var count: Int
        /// The header's foot before the change.
        var lip: CGFloat
        /// Closing: its rows' frames before the change, by their index paths then.
        var before: [IndexPath: CGRect] = [:]
        /// How far the rows travel (the last row's foot to the header's foot), worked out once the new layout is ready.
        var shift: CGFloat?
    }
    var unfold: Unfold?

    /// How far the moving rows travel: opening, from the header's foot before to the last row's foot after; closing,
    /// from the last row's foot before to the header's foot after.
    func unfoldShift() -> CGFloat? {
        guard var unfold else { return nil }
        if let shift = unfold.shift { return shift }
        let shift: CGFloat?
        if unfold.opening {
            shift = unfold.count > 0
                ? layoutAttributesForItem(at: IndexPath(item: unfold.count - 1, section: unfold.section)).map { $0.frame.maxY - unfold.lip }
                : nil
        } else {
            let lip = layoutAttributesForSupplementaryView(ofKind: UICollectionView.elementKindSectionHeader,
                                                          at: IndexPath(item: 0, section: unfold.section))?.frame.maxY
            shift = unfold.before.values.map(\.maxY).max().flatMap { bottom in lip.map { bottom - $0 } }
        }
        unfold.shift = shift.map { max(0, $0) }
        self.unfold = unfold
        return unfold.shift
    }

    /// Opening: a row starts that far up, its foot at the header's foot (hidden under it), and comes down whole.
    private func unfoldStart(_ path: IndexPath, _ end: UICollectionViewLayoutAttributes?) -> UICollectionViewLayoutAttributes? {
        guard let unfold, unfold.opening, path.section == unfold.section, let shift = unfoldShift(),
              let start = end?.copy() as? UICollectionViewLayoutAttributes else { return nil }
        start.frame.origin.y -= shift
        start.alpha = 1
        return start
    }

    /// Closing: a row ends that far up from where it was, under the header, whole.
    private func unfoldEnd(_ path: IndexPath, _ start: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes? {
        guard let unfold, !unfold.opening, path.section == unfold.oldSection, let frame = unfold.before[path],
              let shift = unfoldShift() else { return nil }
        start.frame = frame.offsetBy(dx: 0, dy: -shift)
        start.alpha = 1
        return start
    }

    override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        unfoldStart(itemIndexPath, layoutAttributesForItem(at: itemIndexPath))
            ?? super.initialLayoutAttributesForAppearingItem(at: itemIndexPath)
    }

    override func finalLayoutAttributesForDisappearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        let base = super.finalLayoutAttributesForDisappearingItem(at: itemIndexPath)
        let start = base?.copy() as? UICollectionViewLayoutAttributes ?? UICollectionViewLayoutAttributes(forCellWith: itemIndexPath)
        return unfoldEnd(itemIndexPath, start) ?? base
    }

    override func initialLayoutAttributesForAppearingDecorationElement(ofKind elementKind: String,
                                                                       at decorationIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard elementKind == Self.cardUnderRow,
              let start = unfoldStart(decorationIndexPath, layoutAttributesForDecorationView(ofKind: elementKind, at: decorationIndexPath))
        else { return super.initialLayoutAttributesForAppearingDecorationElement(ofKind: elementKind, at: decorationIndexPath) }
        return start
    }

    override func finalLayoutAttributesForDisappearingDecorationElement(ofKind elementKind: String,
                                                                        at decorationIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        let base = super.finalLayoutAttributesForDisappearingDecorationElement(ofKind: elementKind, at: decorationIndexPath)
        guard elementKind == Self.cardUnderRow else { return base }
        var start = base?.copy() as? UICollectionViewLayoutAttributes
        if start == nil {
            start = UICollectionViewLayoutAttributes(forDecorationViewOfKind: elementKind, with: decorationIndexPath)
            start?.zIndex = -10
        }
        return start.flatMap { unfoldEnd(decorationIndexPath, $0) } ?? base
    }
}

/// The piece of card under a chat (`SessionsListLayout.cardUnderRow`).
final class ProjectCardUnderRow: UICollectionReusableView {
    private let piece = ProjectCardSliceView(slice: .middle)
    /// [project-unfold] Its chat's place, so an opening or closing group can mask it with its chat.
    private(set) var indexPath: IndexPath?

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        indexPath = layoutAttributes.indexPath
    }

    /// [project-unfold] Its chat's piece of the project's line, drawn here while a project opens: the chat hides its own
    /// piece meanwhile (`SessionListCell.cardPieceHidden`), and with this one bare the line through the chats came only
    /// once the spring had settled, ~0.4 s after the card looked open (owner 2026-11-09, screen recording). None at rest,
    /// so a swiping chat's line still goes with it ([card-line-swipe]).
    var line: ProjectCardSliceView.Line {
        get { piece.line }
        set { piece.line = newValue }
    }

    // [project-unfold] One that left mid-fold kept its faded mask: whole again.
    override func prepareForReuse() {
        super.prepareForReuse()
        layer.mask = nil
        line = .none
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        piece.frame = bounds
        piece.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(piece)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        piece.fillColor = ProjectCard.fill     // read again: the theme may have changed since this view was made
    }
}

/// A chat's cell. In an open project's card, what it draws stops at the card's edges while a swipe moves it, so the chat
/// slides inside the card instead of out over the page. While a cell swipes, UIKit masks it to the list with a view it
/// moves against the cell in step with the slide; in a card that mask's opaque part is narrowed to the card. (A mask of
/// our own lagged the slide's animation: the chat flickered half cut.) No mask from UIKit: the cell isn't swiping and
/// stands inside the card anyway.
final class SessionListCell: UICollectionViewListCell {
    var clipsToCard = false { didSet { fitMask() } }
    private static let cardPiece = 0x48514350

    override var mask: UIView? { didSet { fitMask(); fitPiece() } }

    /// [card-line-swipe] Where the list put it across. A swipe moves the cell by frame; UIKit's mask only comes once
    /// the buttons do, so a short pull would slide the line along with it.
    private var laidOutX: CGFloat?
    private var slid: Bool { laidOutX.map { abs(frame.minX - $0) > 0.5 } ?? false }

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        laidOutX = layoutAttributes.frame.minX
        fitPiece()
    }

    override var frame: CGRect {
        didSet { if frame.minX != oldValue.minX { fitPiece() } }
    }

    /// [project-unfold] Its own piece of card hidden while a fold moves it, faded: over the piece under it the two read
    /// lighter than the card around them. The one under it (`ProjectCardUnderRow`, with the card's edges) draws it alone.
    var cardPieceHidden = false { didSet { fitPiece() } }
    /// [project-unfold] Its own piece of card draws the card's edges too, while a project closes: the one under it
    /// (which has them) goes at once.
    var cardPieceEdged = false {
        didSet {
            guard cardPieceEdged != oldValue else { return }
            if cardPieceEdged { fitPiece() } else { setNeedsUpdateConfiguration() }
        }
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        fitPiece()
    }

    private func fitPiece() {
        // [card-line-swipe] While it slides (UIKit's mask is on, or it stands off its place), the piece under it draws
        // alone: its own piece, and the line in it, would slide with the chat. So its piece of the line is gone meanwhile.
        backgroundConfiguration?.customView?.isHidden = (cardPieceHidden || mask != nil || slid) && clipsToCard
        if cardPieceEdged && clipsToCard { (backgroundConfiguration?.customView as? ProjectCardSliceView)?.edged = true }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cardPieceHidden = false
        cardPieceEdged = false
    }

    private func fitMask() {
        guard let mask else { return }
        let piece = mask.viewWithTag(Self.cardPiece)
        guard clipsToCard else {
            if let piece {
                piece.removeFromSuperview()
                mask.backgroundColor = .black
            }
            return
        }
        guard piece == nil else { return }
        // The mask is the list's bounds; the card stands `inset` in from its sides, and inside its edges if it has them.
        let card = UIView(frame: mask.bounds.insetBy(dx: ProjectCard.inset + (ProjectCard.edge == nil ? 0 : ProjectCard.edgeWidth), dy: 0))
        card.tag = Self.cardPiece
        card.backgroundColor = .black
        card.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mask.backgroundColor = .clear
        mask.addSubview(card)
    }
}

/// [project-unfold] A group's header. Over the first project, "Projects" is a view of its own beside the content (not
/// in it): the list moves the content as the project opens or closes (the row going into its card), and the caption
/// above stays where it is.
final class SessionHeaderCell: UICollectionViewListCell {
    private(set) var captionView: (UIView & UIContentView)?

    var caption: UIContentConfiguration? {
        didSet {
            guard let caption else {
                captionView?.removeFromSuperview()
                captionView = nil
                return
            }
            if let captionView, captionView.supports(caption) {
                captionView.configuration = caption
                return
            }
            captionView?.removeFromSuperview()
            let view = caption.makeContentView()
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            captionView = view
        }
    }

    // VoiceOver reads "Projects" first, then the row.
    override var accessibilityElements: [Any]? {
        get { captionView.map { [$0, contentView] } ?? super.accessibilityElements }
        set { super.accessibilityElements = newValue }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        caption = nil
    }

    /// [sessions-collapse] "Projects" takes its own taps (it closes every project; See All, Edit): kept over the
    /// content, which UIKit's list cell can bring back to the front as it lays out.
    override func layoutSubviews() {
        super.layoutSubviews()
        if let captionView, subviews.last !== captionView { bringSubviewToFront(captionView) }
    }
}

/// The same piece of card in SwiftUI (the header, New Chat). `highlight`: a dragged chat is held over the project.
struct ProjectCardFill: View {
    var slice: ProjectCardSlice
    var highlight = false
    /// The card's fill under the highlight; false: the highlight alone, over a `ProjectCardPiece`.
    var fills = true

    var body: some View {
        GeometryReader { geo in
            let box = ProjectCard.box(for: slice, in: CGRect(origin: .zero, size: geo.size))
            let shape = RoundedRectangle(cornerRadius: ProjectCard.radius, style: .continuous)
            shape
                .fill(fills ? Color(uiColor: ProjectCard.fill) : .clear)
                .overlay { if highlight { shape.fill(Color.hqTint.opacity(0.12)) } }
                .overlay {
                    if highlight {
                        shape.strokeBorder(Color.hqTint.opacity(0.55), lineWidth: 1.5)
                    } else if fills, let edge = ProjectCard.edge {
                        shape.strokeBorder(Color(uiColor: edge), lineWidth: 1)
                    }
                }
                .frame(width: box.width, height: box.height)
                .offset(x: box.minX, y: box.minY)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// [project-unfold] A project header's piece of card in UIKit, so its fade as the project opens or closes is Core
/// Animation's: the list's spring, begun with the chats' own fade as the change is committed. SwiftUI's fade ran about
/// 4 frames behind theirs, a seam where the folder's card met the chats' (2026-11-02, frame by frame). A tap mid-fade
/// turns it round from where it stands, as the chats' does.
struct ProjectCardPiece: UIViewRepresentable {
    var slice: ProjectCardSlice
    var shown: Bool
    /// A fold's motion runs: the change fades on its spring, otherwise it's at once.
    var fades: Bool

    func makeUIView(context: Context) -> ProjectCardSliceView {
        let view = ProjectCardSliceView(slice: slice)
        view.alpha = shown ? 1 : 0
        return view
    }

    func updateUIView(_ view: ProjectCardSliceView, context: Context) {
        view.slice = slice
        Self.fade(view, shown: shown, fades: fades)
    }

    /// In or out on the fold's spring (`fades`), from where its fade stands; otherwise at once.
    static func fade(_ view: UIView, shown: Bool, fades: Bool) {
        let alpha: CGFloat = shown ? 1 : 0
        guard view.alpha != alpha else { return }
        let from = view.layer.presentation().map { CGFloat($0.opacity) } ?? view.alpha
        UIView.performWithoutAnimation { view.alpha = alpha }
        view.layer.removeAnimation(forKey: "fade")
        guard fades else { return }
        view.layer.add(SessionsViewController.unfoldFade(from: from - alpha), forKey: "fade")
    }
}

/// [project-unfold] An open project header's piece of the project's line, from under the folder to the first chat, in
/// UIKit so it fades with the header's card (`ProjectCardPiece`): on SwiftUI's fade it stayed under the folder 4-6
/// frames after the card had gone (2026-11-03, frame by frame). Drawn as `ProjectLine` draws it.
struct ProjectLinePiece: UIViewRepresentable {
    var top: CGFloat
    var shown: Bool
    var fades: Bool

    final class LineView: UIView {
        var top: CGFloat = 0 { didSet { if top != oldValue { setNeedsLayout() } } }
        private let line = CAShapeLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            line.fillColor = nil
            line.lineWidth = ProjectCard.lineWidth
            line.lineCap = .butt
            layer.addSublayer(line)
            registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: LineView, _) in view.setNeedsLayout() }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let x = ProjectCard.lineX
            line.path = bounds.height > top ? UIBezierPath(rect: CGRect(x: x, y: top, width: 0, height: bounds.height - top)).cgPath : nil
            line.strokeColor = ProjectCard.line.resolvedColor(with: traitCollection).cgColor   // read again: the theme may have changed
            CATransaction.commit()
        }
    }

    func makeUIView(context: Context) -> LineView {
        let view = LineView()
        view.top = top
        view.alpha = shown ? 1 : 0
        return view
    }

    func updateUIView(_ view: LineView, context: Context) {
        view.top = top
        ProjectCardPiece.fade(view, shown: shown, fades: fades)
    }
}

/// The project's line through one row: from `top` to `bottom` (nil: the row's foot), leaving a gap around the row's node
/// at `node` (`clear` each way). Dashed into New Chat, the place the next chat will go.
struct ProjectLine: View {
    /// The line's centre from the view's leading edge (`cellLineX` in the card's cells).
    var x = ProjectCard.lineX
    var top: CGFloat = 0
    var bottom: CGFloat? = nil
    var node: CGFloat? = nil
    var clear: CGFloat = 0
    var dashed = false

    var body: some View {
        GeometryReader { geo in
            let end = bottom ?? geo.size.height
            Path { path in
                if let node {
                    let above = node - clear, below = node + clear
                    if above > top { path.move(to: CGPoint(x: x, y: top)); path.addLine(to: CGPoint(x: x, y: above)) }
                    if end > below { path.move(to: CGPoint(x: x, y: below)); path.addLine(to: CGPoint(x: x, y: end)) }
                } else if end > top {
                    path.move(to: CGPoint(x: x, y: top))
                    path.addLine(to: CGPoint(x: x, y: end))
                }
            }
            .stroke(Color(uiColor: ProjectCard.line),
                    style: StrokeStyle(lineWidth: ProjectCard.lineWidth, lineCap: .butt, dash: dashed ? [4, 4] : []))
        }
        .accessibilityHidden(true)
    }
}

/// A bot as a project's card names it: its profile, face and display name.
struct ProjectBot: Hashable {
    var profile: String
    var head: JSONValue?
    var name: String
}

/// A project's header as the top of its card (open; closed, a row on the page): one line, as Pinned's rows (owner,
/// 2026-11-01: "they should just be one line each, so that it's easy just to see the name of the project"). The folder
/// (Home: a house) in a box the size of a face, the name (star, how many chats it holds while closed, caret), then on
/// the right the working dots while a bot works in it (closed), its unread count, and the time of its newest chat
/// (closed). Its bots are VoiceOver's alone: an open card's chats show their own faces.
struct ProjectCardHeader: View {
    var title: String
    var summary: SessionProjectSummary
    var favorite = false
    var folds = true
    var dropTarget = false
    /// [project-unfold] Opening or closing: what changes across the row (the count, time and dots tucking away, the
    /// caret, the card's fill) moves on this. Its move down into the card is the list's (see `rowShift`).
    var motion: Animation? = nil
    /// [header-menus] Room at the far right for the header's ⋯, which its header sets over it (`HeaderMenuSpot`).
    var menuSpot = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorSchemeContrast) private var contrast
    private var large: Bool { typeSize.isAccessibilitySize }
    private var desk: Bool { Theme.isDesktop && !large }
    private var open: Bool { !summary.collapsed }
    // [ui-sizing] Compact's callout, as the chat rows under it.
    private var nameFont: Font { desk || Density.compact ? Font.hq(.callout).weight(.semibold) : Font.hq(.body).weight(.semibold) }
    /// The header sits on its card: open, or closed with a dragged chat held over it.
    private var carded: Bool { open || dropTarget }
    private var boxSize: CGFloat { ProjectCard.face }
    /// An open card's folder stands a little lower than a row's face, clear of the card's rounded top.
    private var topPad: CGFloat { Self.topPad(open: open) }
    static func topPad(open: Bool) -> CGFloat { ProjectCard.rowPad + (open ? ProjectCard.cardTop : 0) }

    var body: some View {
        HStack(alignment: large ? .top : .center, spacing: ProjectCard.columnGap) {
            folder
                .animation(motion, value: carded)   // motion-ok: nil unless a fold's unfold runs (reload skips it under Reduce Motion)
                .geometryGroup()   // [project-unfold] its move down is the list's: only what changes inside it animates
                .frame(width: ProjectCard.column)
            HStack(alignment: .center, spacing: 6) {
                // The count on the name's baseline, so the smaller grey number reads as the name's. [project-unfold]
                // Each piece its own gap before it, so the count's is gone with it while open.
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(title)
                        .font(nameFont)
                        .foregroundStyle(dropTarget ? Color.hqTint : Color.hqLabel)
                        .lineLimit(large ? 3 : 1)
                        .layoutPriority(1)
                    if favorite {
                        // In the name's font, so the symbol centres on its capitals (on the baseline at a caption's
                        // size it sat low: owner, 2026-11-01), then drawn at about a caption's size.
                        Text(Image(systemName: "star.fill"))
                            .font(nameFont)
                            .imageScale(.small)
                            .scaleEffect(0.8)
                            .foregroundStyle(Color.hqLabel3)
                            .fixedSize()
                            .padding(.leading, 6)
                            .accessibilityHidden(true)
                    }
                    // Owner, 2026-11-01: "I want the count next to the project name and the time on the far right",
                    // then "What if there wasn't a backdrop behind the number just to make it blend in more?" and "Should the
                    // number be just a bit softer?": between the time's grey and the caret's (the caret's is too faint for
                    // words), the time's grey under Increase Contrast.
                    if summary.total > 0 {
                        Text("\(summary.total)")
                            .font(Font.hq(desk ? .footnote : .subheadline))
                            .foregroundStyle(Color.hqLabel2.opacity(contrast == .increased ? 1 : 0.75))
                            .monospacedDigit()
                            .fixedSize()
                            .modifier(ClosedRowOnly(shown: summary.collapsed, anchor: .leading, gap: 6, gapEdge: .leading))
                            .accessibilityHidden(true)
                    }
                }
                .layoutPriority(1)
                if folds {
                    Image(systemName: "chevron.down")
                        .font(Font.hq(.caption).weight(.semibold))
                        .foregroundStyle(Color.hqLabel3)
                        .rotationEffect(.degrees(summary.collapsed ? -90 : 0))
                }
                Spacer(minLength: 4)
                trailing
            }
            .frame(minHeight: boxSize)
            // [project-unfold] An open card's right edge further in, inside the row, so it moves with the rest across.
            .padding(.trailing, open ? max(0, ProjectCard.trailing - ProjectCard.pageTrailing) : 0)
            // [project-unfold] Across only: nothing in here moves up or down, so a busy moment can't make the row jolt.
            .animation(motion, value: summary.collapsed)   // motion-ok: nil unless a fold's unfold runs (reload skips it under Reduce Motion)
            .geometryGroup()   // [project-unfold] its move down is the list's: only what changes inside it animates
        }
        .padding(.top, topPad)
        .padding(.bottom, ProjectCard.rowPad)
        .padding(.leading, ProjectCard.lead)
        .padding(.trailing, ProjectCard.pageTrailing)
        .frame(maxWidth: .infinity, alignment: .leading)
        // [project-unfold] Both always there, faded in and out: only the fade animates (a removed piece faded where it
        // stood while its row moved), the move down is the list's.
        .background(alignment: .topLeading) {
            // An open card's line leaves the folder for the first chat.
            ProjectLinePiece(top: topPad + boxSize + ProjectCard.lineClearance, shown: open, fades: motion != nil)
        }
        .background {
            // [project-unfold] The top of a card unless a closed row is held as a drop target: closing, a whole card's
            // rounded foot left notches of page at the chats' straight top on their way in.
            let slice: ProjectCardSlice = open || !dropTarget ? .top : .whole
            ProjectCardPiece(slice: slice, shown: carded, fades: motion != nil)
                .overlay { if dropTarget { ProjectCardFill(slice: slice, highlight: true, fills: false) } }
        }
        .animation(HQMotion.reduced ? nil : .snappy(duration: 0.2), value: dropTarget)
    }

    /// A folder (Home: a house) in a small box, where a chat row has its face.
    private var folder: some View {
        Image(systemName: summary.home ? "house" : "folder")
            .font(.system(size: boxSize * 0.52, weight: .medium))     // a11y-font-ok: sized to the face column, as the faces
            .foregroundStyle(Color.hqLabel2)
            .frame(width: boxSize, height: boxSize)
            .background(RoundedRectangle(cornerRadius: desk ? 6 : 8, style: .continuous)
                .fill(Color(uiColor: carded ? ProjectCard.box : ProjectCard.boxOnPage)))
            .overlay {
                // The Desktop Look's page and card are close in light: its outline keeps the box.
                if let edge = ProjectCard.edge {
                    RoundedRectangle(cornerRadius: desk ? 6 : 8, style: .continuous).strokeBorder(Color(uiColor: edge), lineWidth: 1)
                }
            }
            .accessibilityHidden(true)
    }

    /// The time at a chat row's size on the far right, so a closed project's reads as Pinned's do (in the tint while
    /// it holds an unread chat, as an unread chat's time), the working dots and unread count before it.
    @ViewBuilder private var trailing: some View {
        HStack(spacing: 0) {
            WorkingDots()
                .modifier(ClosedRowOnly(shown: summary.collapsed && summary.working, anchor: .trailing,
                                        gap: summary.unread > 0 ? 8 : 0, gapEdge: .trailing))
            if summary.unread > 0 { ProjectCountBadge(count: summary.unread) }
            if large && menuSpot {
                // [header-menus] At the accessibility sizes the ⋯ goes under the time: beside it, the name lost the
                // little room it has (a row read "1 › 4:04 AM ⋯", no name).
                VStack(alignment: .trailing, spacing: 0) {
                    time
                    menuSpotView
                }
            } else {
                time
                if menuSpot { menuSpotView.padding(.leading, 8) }
            }
        }
    }

    @ViewBuilder private var time: some View {
        if !summary.time.isEmpty {
            Text(summary.time)
                .font(Font.hq(desk ? .caption2 : DeviceWord.isMac ? .caption : .subheadline))
                .foregroundStyle(summary.unread > 0 ? Color.hqTint : Color.hqLabel2)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()   // [ui-sizing] whole: a long project name squeezed it to "Yest…"
                .modifier(ClosedRowOnly(shown: summary.collapsed, anchor: .trailing, gap: 8, gapEdge: .leading))
        }
    }

    /// [header-menus] The ⋯'s glyph width, so the glyph ends on the row's trailing edge where the time did (and on an
    /// open card's, as its chats' times); its 44 pt touch reaches past it on both sides.
    private var menuSpotView: some View {
        Color.clear
            .frame(width: desk ? 16 : 18, height: boxSize)
            .anchorPreference(key: HeaderMenuSpot.self, value: .bounds) { $0 }
            .accessibilityHidden(true)
    }
}

/// [project-unfold] A piece of a closed project's row alone (its count, the working dots, its time), kept at no width
/// while it's open: opening or closing, it narrows under its neighbour or widens out from behind it as that moves over
/// (added and taken away, it faded in where it stands, and the caret or the unread count ran across it).
private struct ClosedRowOnly: ViewModifier {
    var shown: Bool
    /// The side it holds to as it narrows (away from the neighbour that covers it).
    var anchor: HorizontalAlignment
    /// Its gap from the next piece on `gapEdge`, which closes with it.
    var gap: CGFloat
    var gapEdge: Edge.Set
    func body(content: Content) -> some View {
        content
            .modifier(Unroll(shown: shown ? 1 : 0, anchor: anchor, gap: gap, gapEdge: gapEdge))
            .accessibilityHidden(!shown)
    }
}

/// [project-unfold] Its width and its fade on one animated value: the width as `UnrollLayout`, and whole letters faded,
/// not cut (clipped as it narrowed, a time read "•M", "• PM", "3:54 PM" on its way to "8:54 PM": owner on 679, "not
/// perfect"). It shows only over the last part of its width, so what's half there is all but gone.
private struct Unroll: ViewModifier, Animatable {
    var shown: CGFloat
    var anchor: HorizontalAlignment
    /// Its gap closes on the same value (a gap of its own, padded on, closed at once as a quick tap turned the fold
    /// round, while the width and fade went on: the count stood against the name for a moment, "Website1").
    var gap: CGFloat = 0
    var gapEdge: Edge.Set = .leading
    var animatableData: CGFloat {
        get { shown }
        set { shown = newValue }
    }
    func body(content: Content) -> some View {
        UnrollLayout(shown: shown, anchor: anchor, gap: gap, gapEdge: gapEdge) {
            content.opacity(Double(max(0, min(1, (shown - 0.5) / 0.5))))
        }
    }
}

/// [project-unfold] Its one view at `shown` of its width, held to `anchor`, a width stepped frame by frame (by `Unroll`)
/// as the row moves into its card: a frame going from its own width to none moved at once to the row's new place,
/// ahead of the row.
private struct UnrollLayout: Layout {
    /// Stepped by `Unroll`, which animates (animating here too ran the width on a second clock).
    var shown: CGFloat
    var anchor: HorizontalAlignment
    /// Its gap from the next piece on `gapEdge`, part of its width.
    var gap: CGFloat
    var gapEdge: Edge.Set

    /// Its view whole, whatever the row offers (offered its part, a time came out cut short: "Yesterd…").
    private func whole(_ view: LayoutSubview, _ proposal: ProposedViewSize) -> CGSize {
        view.sizeThatFits(ProposedViewSize(width: nil, height: proposal.height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let size = whole(view, proposal)
        return CGSize(width: (size.width + gap) * shown, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        let size = whole(view, proposal)
        let x = anchor == .trailing
            ? bounds.maxX - size.width - (gapEdge == .trailing ? gap * shown : 0)
            : bounds.minX + (gapEdge == .leading ? gap * shown : 0)
        view.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(size))
    }
}

/// A count in a tinted capsule (a project's unread).
struct ProjectCountBadge: View {
    var count: Int
    var body: some View {
        Text(BadgeMath.badge(count))
            .font(Font.hq(.caption).weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(Color.hqOnTint)
            .padding(.horizontal, 7)
            .frame(minWidth: 20, minHeight: 20)
            .background(Capsule().fill(Color.hqTint))
            .accessibilityHidden(true)
    }
}

/// Three dots in the tint, the middle one breathing: a bot is at work in a closed project.
private struct WorkingDots: View {
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle().fill(Color.hqTint).frame(width: 5, height: 5).opacity([0.4, 0.7, 1][index])
            }
        }
        .accessibilityHidden(true)
    }
}

/// The card's foot: New Chat, the next stop on the line. A tap asks which bot: the project's own bots first (the one
/// with its newest chat, or the picked chip's, ticked), then Other Bots… (every bot, Choose a Bot).
struct ProjectNewChatRow: View {
    var title: String
    var bots: [ProjectBot]
    var pick: String?
    var otherBots: Bool
    var onPick: (String) -> Void
    var onOther: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    private var desk: Bool { Theme.isDesktop && !typeSize.isAccessibilitySize }
    private var picked: ProjectBot? { bots.first { $0.profile == pick } ?? bots.first }

    var body: some View {
        // One tap starts the chat with the bot shown (owner, 2026-11-02: the menu first was "not good UX"); the bot
        // on the right is its own menu, for another.
        Button {
            if let picked { onPick(picked.profile) } else { onOther() }
        } label: {
            HStack(spacing: ProjectCard.columnGap) {
                Image(systemName: "plus")
                    .font(.system(size: ProjectCard.face * 0.5, weight: .medium))     // a11y-font-ok: sized to the node, as the faces
                    .foregroundStyle(Color.hqTint)
                    .frame(width: ProjectCard.face, height: ProjectCard.face)
                    .overlay(Circle().strokeBorder(Color.hqTint, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5])))
                    .frame(width: ProjectCard.column)
                Text("New Chat")
                    .font(desk || Density.compact ? Font.hq(.callout) : Font.hq(.body))   // [ui-sizing] Compact too
                    .foregroundStyle(Color.hqTintText)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.vertical, ProjectCard.rowPad)
            .padding(.leading, ProjectCard.cellLead)
            .padding(.trailing, ProjectCard.cellTrailing)
            .frame(maxWidth: .infinity, minHeight: ProjectCard.rowPad * 2 + ProjectCard.face, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New Chat in \(title)")
        .accessibilityValue(picked.map { "With \($0.name)" } ?? "")
        .accessibilityIdentifier("sessions.project.newChat")
        .overlay(alignment: .trailing) {
            if let picked { botMenu(picked) }
        }
        .background(alignment: .topLeading) {
            ProjectLine(x: ProjectCard.cellLineX, bottom: ProjectCard.nodeY - ProjectCard.face / 2 - ProjectCard.lineClearance, dashed: true)
        }
        .padding(.bottom, ProjectCard.cardTop)
        .background { ProjectCardFill(slice: .bottom) }
    }

    /// The bot a new chat starts with, as a capsule: its menu starts one with another of the project's bots.
    private func botMenu(_ picked: ProjectBot) -> some View {
        Menu {
            Section("New Chat With") {
                ForEach(bots, id: \.profile) { bot in
                    Button { onPick(bot.profile) } label: {
                        if bot.profile == picked.profile { Label(bot.name, systemImage: "checkmark") } else { Text(bot.name) }
                    }
                }
            }
            if otherBots {
                Button { onOther() } label: { Label("Other Bots…", systemImage: "person.2") }
            }
        } label: {
            HStack(spacing: 5) {
                HeadImage(raw: picked.head, profile: picked.profile, size: HQFont.scaled(desk ? 14 : 16))
                Text(picked.name)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(Font.hq(.caption2).weight(.semibold))
            }
            .font(Font.hq(desk ? .footnote : .subheadline))
            .foregroundStyle(Color.hqLabel2)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.hqLabel2.opacity(0.12)))
            // The whole height of the row, so a tap beside the capsule isn't taken as New Chat.
            .frame(maxHeight: .infinity)
            .padding(.leading, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuOrder(.fixed)
        // The name 4 pt in from the times above it, so the capsule keeps clear of the card's edge.
        .padding(.trailing, ProjectCard.cellTrailing - 4)
        .accessibilityLabel("Bot for New Chat")
        .accessibilityValue(picked.name)
        .accessibilityIdentifier("sessions.project.newChatBot")
    }
}

/// Show More inside a card: a hollow node on the line, then "Show More (X)" or "Show Less".
struct ProjectShowMoreRow: View {
    var more: Int
    @Environment(\.dynamicTypeSize) private var typeSize
    private var desk: Bool { Theme.isDesktop && !typeSize.isAccessibilitySize }

    var body: some View {
        HStack(spacing: ProjectCard.columnGap) {
            Circle()
                .strokeBorder(Color(uiColor: ProjectCard.line), lineWidth: 2)
                .frame(width: 10, height: 10)
                .frame(width: ProjectCard.column)
            Text(more > 0 ? "Show More (\(more))" : "Show Less")
                .font(Font.hq(desk ? .footnote : .subheadline).weight(.medium))
                .foregroundStyle(Color.hqTintText)
            Spacer(minLength: 0)
        }
        .padding(.leading, ProjectCard.cellLead)
        .padding(.trailing, ProjectCard.cellTrailing)
        .frame(minHeight: ProjectCard.rowPad * 2 + ProjectCard.face)
        .background(alignment: .topLeading) {
            ProjectLine(x: ProjectCard.cellLineX, node: ProjectCard.nodeY, clear: 5 + ProjectCard.lineClearance)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SessionRowWords.showMoreLabel(more))
        .accessibilityAddTraits(.isButton)
    }
}
