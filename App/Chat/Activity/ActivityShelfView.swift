import UIKit

// The shelf above the composer (docs/spec/1x-activity.md §7): Goal, Tasks, Subagents and Previous tasks as folded chips
// on native Liquid Glass that float over the transcript, each opening into a glass card in place (the owner rejected a
// sheet, M:subagent-card-glass.md). All pieces share one `UIGlassContainerEffect` (spacing 4 < the 6 pt gap: they never
// merge at rest but morph when a chip opens into a card). Only the pieces take touches: everything else reaches the
// transcript and the jump button underneath (M:jump-arrow-under-dock.md).

enum ShelfPieceKind: Int, CaseIterable, Hashable {
    case goal, tasks, subagents, previousTasks
    /// [browser] "Browsing example.com" while the chat's bot uses its browser: a chip that opens Watch Browser.
    case browser
}

/// The shelf: pieces stacked top → bottom in `ShelfPieceKind` order, 6 pt apart; folded chips hug their words and are
/// centred, opened cards span the shelf.
final class ActivityShelfView: UIView {
    private let container: UIVisualEffectView = {
        let effect = UIGlassContainerEffect()
        effect.spacing = 4
        return UIVisualEffectView(effect: effect)
    }()
    /// UX study #230: with only folded chips that still don't fit (many of them at accessibility sizes, the keyboard up)
    /// they scroll here, so a strip of transcript stays in sight. Never while a card is open (it has its own scroller).
    private let scroller: UIScrollView = {
        let view = UIScrollView()
        view.contentInsetAdjustmentBehavior = .never
        view.clipsToBounds = false
        view.isScrollEnabled = false
        view.alwaysBounceVertical = false
        view.accessibilityIdentifier = "chat.shelf.scroll"
        return view
    }()
    /// UX study #230: folded chips keep to one line (their words truncate; VoiceOver reads them whole) when the wrapped
    /// ones would not fit.
    private(set) var compactChips = false
    private(set) var pieces: [ShelfPieceKind: ShelfPieceView] = [:]
    /// The tallest an opened card may be (set by the chat from its visible height).
    var maxCardHeight: CGFloat = 300 { didSet { if maxCardHeight != oldValue { setNeedsLayout() } } }
    /// The tallest the whole shelf may be: the room between the status line and what it sits on (verify round 2: with
    /// the keyboard up, a tall draft and a queue card, opened cards pushed the shelf up under the title and the status
    /// capsule). Opened cards give way first (their bodies scroll); then wrapped chips keep to one line, and folded
    /// chips alone scroll (UX study #230).
    var maxHeight: CGFloat = .greatestFiniteMagnitude { didSet { if maxHeight != oldValue { setNeedsLayout() } } }
    static let gap: CGFloat = 6
    /// An opened card never shrinks below its header and this much body.
    static let minCardBody: CGFloat = 60

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        container.clipsToBounds = false
        container.contentView.clipsToBounds = false
        scroller.addSubview(container)
        addSubview(scroller)
        accessibilityIdentifier = "chat.shelf"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func piece(_ kind: ShelfPieceKind, make: () -> ShelfPieceView) -> ShelfPieceView {
        if let p = pieces[kind] { return p }
        let p = make()
        pieces[kind] = p
        container.contentView.addSubview(p)
        return p
    }

    /// The pieces that show, top → bottom.
    var visiblePieces: [ShelfPieceView] {
        ShelfPieceKind.allCases.compactMap { pieces[$0] }.filter { $0.isPresent }
    }

    /// The shelf's height for `width` (0 when nothing shows): its pieces', or with only folded chips at most `maxHeight`
    /// (never under one chip), the rest scrolling.
    func height(for width: CGFloat) -> CGFloat {
        let content = contentHeight(width: width)
        guard content > 0, !hasOpenCard else { return content }
        return min(content, max(maxHeight, 44))
    }

    /// Every present piece stacked, 6 pt apart.
    private func contentHeight(width: CGFloat) -> CGFloat {
        let sizes = pieceSizes(width: width)
        guard !sizes.isEmpty else { return 0 }
        return sizes.reduce(0) { $0 + $1.size.height } + CGFloat(sizes.count - 1) * Self.gap
    }

    /// The present pieces top → bottom with their sizes: each opened card capped at `maxCardHeight`, then the tallest
    /// cards shortened (never below a header + `minCardBody`) until the shelf fits `maxHeight`.
    private func pieceSizes(width: CGFloat) -> [(piece: ShelfPieceView, size: CGSize)] {
        let present = ShelfPieceKind.allCases.compactMap { pieces[$0] }.filter(\.isPresent)
        var sizes = present.map { p in (piece: p, size: p.size(for: width, maxCard: maxCardHeight)) }
        guard !sizes.isEmpty else { return sizes }
        var excess = sizes.reduce(0) { $0 + $1.size.height } + CGFloat(sizes.count - 1) * Self.gap - maxHeight
        // UX study #230: wrapped chips that take the room keep to one line instead.
        let compact = excess > 0.5 && present.contains { !$0.isOpen && $0.header.wraps }
        if compact != compactChips { compactChips = compact; setNeedsLayout() }
        if compact {
            sizes = present.map { p in (piece: p, size: p.size(for: width, maxCard: maxCardHeight, compact: true)) }
            excess = sizes.reduce(0) { $0 + $1.size.height } + CGFloat(sizes.count - 1) * Self.gap - maxHeight
        }
        guard excess > 0.5 else { return sizes }
        let floors = sizes.map { $0.piece.isOpen ? min($0.size.height, $0.piece.minCardHeight(width: width)) : $0.size.height }
        // A point at a time from the tallest card that can still give (a few hundred steps at most).
        while excess > 0 {
            let shrinkable = sizes.indices.filter { sizes[$0].size.height - floors[$0] > 0.01 }
            guard let i = shrinkable.max(by: { sizes[$0].size.height < sizes[$1].size.height }) else { break }
            let step = min(excess, 1, sizes[i].size.height - floors[i])
            sizes[i].size.height -= step
            excess -= step
        }
        return sizes.map { ($0.piece, CGSize(width: $0.size.width, height: $0.size.height.rounded(.down))) }
    }

    /// Where each present piece goes at `width`, top → bottom.
    func targetFrames(width: CGFloat) -> [ShelfPieceKind: CGRect] {
        var out: [ShelfPieceKind: CGRect] = [:]
        var y: CGFloat = 0
        for (p, size) in pieceSizes(width: width) {
            let x = p.isOpen ? 0 : ((width - size.width) / 2).rounded()
            out[p.kind] = CGRect(x: x, y: y, width: size.width, height: size.height)
            y += size.height + Self.gap
        }
        return out
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for p in pieces.values { p.header.compact = compactChips }
        // The pieces' own height; past the shelf's (folded chips only) they scroll, clipped to the shelf.
        let content = max(bounds.height, contentHeight(width: bounds.width))
        let overflows = content > bounds.height + 0.5
        scroller.frame = bounds
        scroller.contentSize = CGSize(width: bounds.width, height: content)
        scroller.isScrollEnabled = overflows
        scroller.clipsToBounds = overflows
        scroller.showsVerticalScrollIndicator = overflows
        if !overflows, scroller.contentOffset != .zero { scroller.contentOffset = .zero }
        if scroller.contentOffset.y > content - bounds.height { scroller.contentOffset.y = max(0, content - bounds.height) }
        container.frame = CGRect(x: 0, y: 0, width: bounds.width, height: content)
        // Bounds and centre, never `frame`: an arriving piece is scaled while it fades in.
        let targets = targetFrames(width: bounds.width)
        for p in pieces.values {
            if let frame = targets[p.kind] {
                p.place(frame)
            } else if !p.isHidden, let fromBottom = p.leavingFromBottom {
                // A leaving piece fades where it stands on screen: the shelf's bottom is pinned, so the piece keeps its
                // distance from it while the shelf's top moves. (Its own `frame` can't be read here: Auto Layout sets
                // the new bounds before the new centre.)
                var frame = CGRect(origin: .zero, size: p.bounds.size)
                frame.origin.x = p.center.x - p.bounds.width / 2
                frame.origin.y = content - fromBottom
                p.place(frame)
            }
        }
    }

    /// Only the pieces take touches (the jump button and the transcript stay reachable beside the chips).
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if scroller.isScrollEnabled, !bounds.contains(point) { return false }
        return visiblePieces.contains { frame(of: $0).contains(point) }
    }

    /// A piece's frame in the shelf's coordinates (the chips may be scrolled).
    private func frame(of piece: ShelfPieceView) -> CGRect {
        container.contentView.convert(piece.frame, to: self)
    }

    /// The pieces' stacked height (a leaving piece keeps its distance from its bottom).
    var piecesHeight: CGFloat { container.bounds.height }

    /// The widest folded chip's trailing edge in `view`'s coordinates (the jump button moves above the shelf when a chip
    /// comes within 8 pt of it).
    func chipsTrailingEdge(in view: UIView) -> CGFloat {
        visiblePieces.filter { !$0.isOpen }.map { container.contentView.convert($0.frame, to: view).maxX }.max() ?? 0
    }

    var hasOpenCard: Bool { visiblePieces.contains(where: \.isOpen) }
}

/// One piece: a glass element of the shelf's container holding the chip header (always) and, when open, the card's
/// body in one scroller (owner: one scroller, never nested ones — M:subagent-card-glass.md).
final class ShelfPieceView: UIVisualEffectView {
    let kind: ShelfPieceKind
    let header = ShelfHeader()
    let scroll = UIScrollView()
    /// The body (subagents, tasks or goal content); laid out with Auto Layout inside the scroller.
    let body: UIView
    private(set) var isOpen = false
    /// Shown (false while hidden or fading out).
    private(set) var isPresent = false
    /// While a leaving piece fades: its top's distance above the shelf's (pinned) bottom, kept while the shelf shrinks.
    var leavingFromBottom: CGFloat?
    var onToggle: (() -> Void)?

    init(kind: ShelfPieceKind, body: UIView) {
        self.kind = kind
        self.body = body
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        super.init(effect: effect)
        isHidden = true
        alpha = 0
        cornerConfiguration = .capsule()
        header.addTarget(self, action: #selector(toggled), for: .touchUpInside)
        contentView.addSubview(header)
        // The goal's ⋯ sits over the header's trailing end, a sibling (the header is one accessibility element).
        contentView.addSubview(header.more)
        scroll.alwaysBounceVertical = false
        scroll.showsVerticalScrollIndicator = true
        scroll.isHidden = true
        scroll.alpha = 0
        contentView.addSubview(scroll)
        body.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            body.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor),
        ])
        accessibilityElements = [header, header.more, scroll]
        // [desktoplook4] The look flattens the glass (ThemeChrome) and puts it back; the shape follows after it.
        themeWatch = NotificationCenter.default.addObserver(forName: Theme.didChange, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyCorners() } }
        }
    }

    private var themeWatch: NSObjectProtocol?
    isolated deinit { if let themeWatch { NotificationCenter.default.removeObserver(themeWatch) } }

    /// Capsule chip, 18 pt card; the Desktop Look's 4 pt corners either way (its flat panels).
    private func applyCorners() {
        cornerConfiguration = Theme.isDesktop ? .corners(radius: .fixed(4)) : isOpen ? .corners(radius: .fixed(18)) : .capsule()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func toggled() {
        Haptics.play(.selection)
        onToggle?()
    }

    func place(_ frame: CGRect) {
        let size = frame.size
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if bounds.size != size { bounds = CGRect(origin: .zero, size: size) }
        if self.center != center { self.center = center }
    }

    /// Chip: the header's own width; card: the shelf's width, the header and as much body as fits.
    func size(for width: CGFloat, maxCard: CGFloat, compact: Bool = false) -> CGSize {
        let headerH = header.height(width: isOpen ? width : nil, compact: compact && !isOpen)
        guard isOpen else { return CGSize(width: min(width, header.fittingWidth), height: headerH) }
        let bodyH = bodyHeight(width: width)
        return CGSize(width: width, height: min(maxCard, headerH + bodyH))
    }

    /// The least an opened card shrinks to when the shelf runs out of room: its header and a little body (it scrolls).
    func minCardHeight(width: CGFloat) -> CGFloat {
        let headerH = header.height(width: width)
        return headerH + min(bodyHeight(width: width), ActivityShelfView.minCardBody)
    }

    /// The body's fitting height, measured once per content change (`ShelfMeasuredBody.layoutRevision`), width and
    /// text size.
    private var measured: (width: CGFloat, revision: Int, category: UIContentSizeCategory, height: CGFloat)?

    func bodyHeight(width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let revision = (body as? ShelfMeasuredBody)?.layoutRevision
        let category = traitCollection.preferredContentSizeCategory
        if let m = measured, let revision, m.revision == revision, m.width == width, m.category == category { return m.height }
        let size = body.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let height = ceil(size.height)
        if let revision { measured = (width, revision, category, height) }
        return height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let headerH = header.height(width: isOpen ? bounds.width : nil, compact: header.compact && !isOpen)
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headerH)
        header.more.frame = CGRect(x: bounds.width - 44, y: (headerH - 44) / 2, width: 44, height: 44)
        scroll.frame = CGRect(x: 0, y: headerH, width: bounds.width, height: max(0, bounds.height - headerH))
    }

    /// Appear (0.2 s fade + scale 0.9 → 1) or leave (0.18 s fade).
    func setPresent(_ present: Bool, animated: Bool) {
        guard present != isPresent else { return }
        isPresent = present
        let motion = animated && window != nil && !HQMotion.reduced
        if present {
            leavingFromBottom = nil
            isHidden = false
            if motion {
                alpha = 0
                transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
                UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {   // motion-ok: `motion` is false under Reduce Motion
                    self.alpha = 1
                    self.transform = .identity
                }
            } else {
                alpha = 1
                transform = .identity
            }
        } else if motion {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseIn, .allowUserInteraction]) {   // motion-ok: `motion` is false under Reduce Motion
                self.alpha = 0
            } completion: { _ in if !self.isPresent { self.isHidden = true; self.leavingFromBottom = nil } }
        } else {
            alpha = 0
            isHidden = true
            leavingFromBottom = nil
        }
        GlyphTicker.shared.setNeedsUpdate()
    }

    /// Chip ↔ card. The frame morphs with the shelf's spring; the body fades in after it settles.
    /// The opened card's glass tint: the page colour at half strength in light, nothing in dark.
    static let cardTint = UIColor { @Sendable traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0)
            : ChatPalette.page.resolvedColor(with: traits).withAlphaComponent(0.55)   // the theme's page, not fixed white (audit 10-17)
    }

    func setOpen(_ open: Bool, animated: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        if effect is UIGlassEffect {
            // Interactive as a chip; an opened card is not (its rows give their own press highlight).
            let next = UIGlassEffect(style: .regular)
            next.isInteractive = !open
            // Verify round 3: an opened card (rows of words, grey ones among them) is tinted with the page in light, so
            // a blue bubble under it no longer washes over its text (MEM subagent-card-glass: the owner found grey text
            // on this glass hard to read). Still the system's glass; dark needed none.
            next.tintColor = open ? Self.cardTint : nil
            effect = next
        }
        applyCorners()
        header.setOpen(open, animated: animated)
        GlyphTicker.shared.setNeedsUpdate()
        if open {
            scroll.isHidden = false
            scroll.contentOffset = .zero
            if animated && !HQMotion.reduced {
                scroll.alpha = 0
                UIView.animate(withDuration: 0.15, delay: 0.2, options: [.allowUserInteraction]) { self.scroll.alpha = 1 }
            } else {
                scroll.alpha = 1
            }
        } else {
            scroll.alpha = 0
            scroll.isHidden = true
        }
    }
}

/// The chip's words, its spinner and a chevron (turned down when open); the goal adds a leading tone dot and a trailing ⋯
/// once open. 44 pt tall, Subheadline (capped at 22), 14 pt leading / 10 pt trailing.
final class ShelfHeader: UIControl {
    let label = UILabel()
    let chevron = UIImageView()
    private(set) var spinner: GlyphSpinner?
    let leadingDot = UIView()
    /// [browser] A symbol before the words (the browser chip's globe), shown whenever it has an image.
    let leadingIcon = UIImageView()
    let more = UIButton(type: .system)
    private var open = false
    var showsMore = false { didSet { more.isHidden = !(showsMore && open); setNeedsLayout() } }
    var showsLeadingDot = false { didSet { leadingDot.isHidden = !(showsLeadingDot && open); setNeedsLayout() } }
    /// UX study #230: a folded chip keeps to one line even at accessibility sizes (the shelf ran out of room).
    var compact = false {
        didSet { guard compact != oldValue else { return }; label.numberOfLines = wrapsNow ? 0 : 1; setNeedsLayout() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textColor = ChatPalette.label
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.isUserInteractionEnabled = false
        addSubview(label)
        chevron.contentMode = .center
        chevron.tintColor = ChatPalette.label2
        chevron.isUserInteractionEnabled = false
        addSubview(chevron)
        leadingDot.layer.cornerRadius = 4
        leadingDot.isHidden = true
        leadingDot.isUserInteractionEnabled = false
        addSubview(leadingDot)
        leadingIcon.contentMode = .center
        leadingIcon.isHidden = true
        leadingIcon.isUserInteractionEnabled = false
        addSubview(leadingIcon)
        more.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        more.tintColor = ChatPalette.label2
        more.isHidden = true
        more.accessibilityLabel = "Goal Actions"
        more.showsMenuAsPrimaryAction = true
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "Shows details"
        updateFonts()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: ShelfHeader, _) in
            view.updateFonts()
            view.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var isLarge: Bool { traitCollection.preferredContentSizeCategory.isAccessibilityCategory }
    /// The words may wrap: a folded chip at accessibility sizes.
    var wraps: Bool { isLarge && !open }
    /// They wrap now (an open card's header always may; a chip unless told to keep to one line).
    private var wrapsNow: Bool { isLarge && !(compact && !open) }

    private func updateFonts() {
        let size = min(HQFont.preferred(.subheadline, compatibleWith: traitCollection).pointSize, 22)
        label.font = HQFont.face(ofSize: size)
        label.numberOfLines = wrapsNow ? 0 : 1
        let config = UIImage.SymbolConfiguration(pointSize: (size * 0.7).rounded(), weight: .semibold)
        chevron.image = UIImage(systemName: "chevron.right", withConfiguration: config)
        // The ⋯ grows with the words too (it stayed at the system's default size while the chevron followed them).
        more.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: size, weight: .semibold), forImageIn: .normal)
        spinner?.font = HQFont.monoFace(ofSize: size, weight: .regular)
    }

    /// The words and whether a spinner (in `color`) follows them.
    func set(words: String, spinner color: UIColor?) {
        if label.text != words { label.text = words; setNeedsLayout() }
        if let color {
            if spinner == nil {
                let s = GlyphSpinner(style: .braille, color: color, size: label.font.pointSize, prescaled: true)
                s.isUserInteractionEnabled = false
                addSubview(s)
                spinner = s
                setNeedsLayout()
            }
            spinner?.textColor = color
        } else if let s = spinner {
            s.removeFromSuperview()
            spinner = nil
            setNeedsLayout()
        }
        accessibilityLabel = words + (color != nil ? ", running" : "")
        accessibilityValue = open ? "expanded" : "collapsed"
    }

    func setOpen(_ open: Bool, animated: Bool) {
        self.open = open
        label.numberOfLines = wrapsNow ? 0 : 1
        more.isHidden = !(showsMore && open)
        leadingDot.isHidden = !(showsLeadingDot && open)
        accessibilityValue = open ? "expanded" : "collapsed"
        let turn = { self.chevron.transform = open ? CGAffineTransform(rotationAngle: .pi / 2) : .identity }
        if animated && !HQMotion.reduced { UIView.animate(withDuration: 0.25, animations: turn) } else { turn() }
        setNeedsLayout()
    }

    /// 44 pt; at accessibility sizes the words wrap and the header grows.
    func height(width: CGFloat?, compact: Bool = false) -> CGFloat {
        guard isLarge else { return 44 }
        if compact { return max(44, ceil(label.font.lineHeight) + 20) }
        let w = max(120, (width ?? 340) - 80)
        let text = label.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height
        return max(44, ceil(text) + 20)
    }

    /// Words + spinner + chevron + paddings.
    var fittingWidth: CGFloat {
        let words = ceil(label.intrinsicContentSize.width)
        let spin = spinner.map { $0.intrinsicContentSize.width + 4 } ?? 0
        let chev: CGFloat = 2 + (chevron.image?.size.width ?? 8) + 4
        let icon: CGFloat = leadingIcon.isHidden ? 0 : 22 + 6
        return 14 + icon + words + 4 + spin + chev + 10
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        var x: CGFloat = 14
        if !leadingDot.isHidden {
            leadingDot.frame = CGRect(x: x, y: (h - 8) / 2, width: 8, height: 8)
            x += 8 + 8
        }
        if !leadingIcon.isHidden {
            leadingIcon.frame = CGRect(x: x, y: (h - 22) / 2, width: 22, height: 22)
            x += 22 + 6
        }
        let trailing: CGFloat = more.isHidden ? 10 : 44
        let chevW = (chevron.image?.size.width ?? 8) + 4
        let spinW = spinner.map { $0.intrinsicContentSize.width } ?? 0
        let available = bounds.width - x - trailing - chevW - 2 - (spinW > 0 ? spinW + 4 : 0) - 4
        let wordsW = min(available, ceil(label.intrinsicContentSize.width))
        let labelH = wrapsNow ? ceil(label.sizeThatFits(CGSize(width: wordsW, height: .greatestFiniteMagnitude)).height) : ceil(label.font.lineHeight)
        label.frame = CGRect(x: x, y: (h - labelH) / 2, width: wordsW, height: labelH)
        x = label.frame.maxX + 4
        if let s = spinner {
            let side = s.intrinsicContentSize.width
            s.frame = CGRect(x: x, y: (h - side) / 2, width: side, height: side)
            x += side + 4
        }
        chevron.frame = CGRect(x: x + 2, y: (h - 16) / 2, width: chevW - 4, height: 16)
    }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.6 : 1 } }
}
