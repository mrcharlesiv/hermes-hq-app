import UIKit

/// Draws one piece of laid-out text (TextKit 1, the same layout `TextLayout` measured with). Redraws only when its
/// text or width changes, so streaming redraws just the block that grew.
final class TextDrawView: UIView {
    private(set) var textKit: TextKitLayout?
    private var text: NSAttributedString?
    private var width: CGFloat?
    /// Goes up whenever the drawing changes (the shimmer's glow re-snapshots the text only then).
    private(set) var drawGeneration = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .topLeft
        isUserInteractionEnabled = false
        layer.drawsAsynchronously = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self, PillInkTrait.self]) { (view: TextDrawView, _) in
            view.drawGeneration += 1
            view.setNeedsDisplay()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func set(_ text: NSAttributedString?, width: CGFloat?) {
        if let text, let current = self.text, width == self.width {
            if text === current { return }
            // A re-rendered but identical string (a part that stopped changing, rendered again after an eviction):
            // keep the layout and the drawing.
            if text.length == current.length && text.isEqual(to: current) { return }
        }
        self.text = text
        self.width = width
        selection = nil
        textKit = text.map { TextKitPool.layout($0, width: width) }
        drawGeneration += 1
        setNeedsDisplay()
    }

    func set(layout: TextKitLayout?) {
        if layout === textKit { return }
        selection = nil
        textKit = layout
        text = layout?.text
        width = nil
        drawGeneration += 1
        setNeedsDisplay()
    }

    /// MENUS (Find in chat): ranges drawn under the text — every match, the current one in its own colour.
    var findHighlights: [FindMark] = [] { didSet { if findHighlights != oldValue { drawGeneration += 1; setNeedsDisplay() } } }

    nonisolated struct FindMark: Hashable {
        var range: NSRange
        var current: Bool
    }

    /// [mac] What the mouse selected in this piece, drawn under the text in `selectionColor`.
    var selection: NSRange? { didSet { if selection != oldValue { drawGeneration += 1; setNeedsDisplay() } } }
    var selectionColor = DesktopFrost.tint(ChatPalette.tint)   // the theme's colour, as iOS's own selection

    override func draw(_ rect: CGRect) {
        if let textKit, let selection {
            selectionColor.setFill()
            for box in textKit.rects(for: selection) { UIBezierPath(rect: box).fill() }
        }
        if let textKit, !findHighlights.isEmpty {
            for mark in findHighlights {
                (mark.current ? ChatFindHighlight.currentColor : ChatFindHighlight.matchColor).setFill()
                for box in textKit.rects(for: mark.range) {
                    UIBezierPath(roundedRect: box.insetBy(dx: -1.5, dy: 0), cornerRadius: 4).fill()
                }
            }
        }
        textKit?.draw(at: .zero)
    }

    func link(at point: CGPoint) -> URL? { textKit?.link(at: point) }
    func copyable(at point: CGPoint) -> String? { textKit?.copyable(at: point) }
}

/// One markdown block inside a bubble: prose, quote, code card or table. Its text is drawn in pieces (see
/// `TextPiece`), and only the pieces near the screen get a view, so a 30,000-character reply draws what shows.
final class BlockView: UIView, UIScrollViewDelegate {
    private let scroll = UIScrollView()
    private let content = UIView()
    private let grid = TableGridView()
    private var pieceViews: [Int: TextDrawView] = [:]
    private var spareViews: [TextDrawView] = []
    private var pieces: [TextPiece] = []
    private var layoutWidth: CGFloat?
    /// [mac] Mac audit #11: each piece's selected range (by piece index) and its colour, kept while a piece has no view
    /// (scrolled far off, or not drawn yet) so the highlight is there again when it comes back.
    private var selectionMarks: [Int: NSRange] = [:]
    private var selectionTint: UIColor = DesktopFrost.tint(ChatPalette.tint)
    /// The screen's visible rect in this view's coordinates (nil = everything counts as visible).
    private var windowRect: CGRect?
    private let label = UILabel()
    private let copyButton = UIButton(type: .system)
    private let bar = UIView()
    private let alertIcon = UIImageView()
    private let fadeView = GradientView()
    private let toggleButton = UIButton(type: .system)
    private let bottomMask = CAGradientLayer()
    private var block: MarkdownBlock?
    private var copyText = ""
    private var copyResetWork: DispatchWorkItem?
    /// The code clamp's toggle (spec 06 §2.6).
    var onToggleCode: (() -> Void)?
    /// [transcript] The table's expand button (docs/spec/3x-transcript.md §3.4, L309).
    var onExpandTable: ((MarkdownTable) -> Void)?
    /// [transcript] A link chip's tap (§3.7).
    var onOpenLink: ((URL) -> Void)?
    private var chip: LinkChipView?
    /// A page card (`PageCardView`): a bot's HTML page pictured, opened live on a tap.
    private var pageCard: PageCardView?
    /// [transcript] A table card's footer: its size and Expand, a button the width of the card.
    private let expandButton = TableFooterControl()
    /// [transcript] A wide table's edges fade where columns go on past them.
    private let edgeFade = CAGradientLayer()
    /// [transcript] The table's Expand button and a link chip, for the bubble's accessibility container: a bubble that
    /// is one element would hide them from VoiceOver.
    var accessibleControls: [UIView] {
        var views: [UIView] = []
        if !expandButton.isHidden, expandButton.isEnabled { views.append(expandButton) }
        if let chip, !chip.isHidden { views.append(chip) }
        if let pageCard, !pageCard.isHidden { views.append(pageCard) }
        return views
    }
    /// Whether this block is a page card: the card is its own element, not part of the bubble's words.
    var showsPageCard: Bool { pageCard.map { !$0.isHidden } ?? false }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        scroll.alwaysBounceVertical = false
        scroll.scrollsToTop = false
        scroll.clipsToBounds = true
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delegate = self
        addSubview(scroll)
        scroll.addSubview(content)
        grid.isHidden = true
        content.addSubview(grid)
        label.font = HQFont.scaled(12, weight: .medium, like: .caption1, cap: 20)
        label.adjustsFontForContentSizeCategory = true   // [a11y] follows a live text-size change
        label.textColor = ChatPalette.label2
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "doc.on.doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        config.baseForegroundColor = ChatPalette.label2
        copyButton.configuration = config
        copyButton.accessibilityLabel = "Copy Code"
        copyButton.addTarget(self, action: #selector(copyCode), for: .touchUpInside)
        addSubview(copyButton)
        expandButton.accessibilityLabel = "Expand table"
        expandButton.accessibilityIdentifier = "chat.table.expand"
        expandButton.isHidden = true
        expandButton.addTarget(self, action: #selector(expandTable), for: .primaryActionTriggered)
        edgeFade.startPoint = CGPoint(x: 0, y: 0.5)
        edgeFade.endPoint = CGPoint(x: 1, y: 0.5)
        addSubview(expandButton)
        bar.backgroundColor = ChatPalette.label3
        bar.layer.cornerRadius = 1
        addSubview(bar)
        alertIcon.contentMode = .scaleAspectFit
        addSubview(alertIcon)
        fadeView.isUserInteractionEnabled = false
        fadeView.color = ChatPalette.codeFillOnBubble
        addSubview(fadeView)
        var toggle = UIButton.Configuration.plain()
        toggle.baseForegroundColor = ChatPalette.label2
        toggleButton.configuration = toggle
        toggleButton.addTarget(self, action: #selector(toggleCode), for: .touchUpInside)
        addSubview(toggleButton)
        bottomMask.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: BlockView, _) in
            if view.desktopOutlined {
                view.outlineForDesktop()
            } else if view.layer.borderWidth > 0 {
                view.layer.borderColor = ChatPalette.separator.resolvedColor(with: view.traitCollection).cgColor
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The table's footer is shorter than 44 pt at the default text size, so its touch area stands a few points past
    /// the card's bottom: a touch there still reaches it instead of falling through to the bubble.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) || (!expandButton.isHidden && expandButton.frame.contains(point))
    }

    /// Code cards that have had their streaming entrance, by row and block.
    private static var entered = Set<String>()

    /// [motion] A code card in a reply still streaming, as on the desktop (V:styles.css:2093 `[data-streaming='true']`):
    /// it arrives from 0.375 rem lower at 74 % opacity over 180 ms on cubic-bezier(0.16, 1, 0.3, 1), then glows, its
    /// 1 pt ring and soft shadow in the accent going 6 %→12 % and 5 %→10 % and back every 1.8 s, easing in and out.
    /// Reduce Motion: no entrance, and the glow holds at its resting 10 % / 8 %. The glow goes when the reply settles.
    func setStreaming(_ on: Bool, key: String) {
        guard case .code? = block, on else {
            guard layer.animation(forKey: "glow") != nil || layer.shadowOpacity > 0 else { return }
            layer.removeAnimation(forKey: "glow")
            layer.borderWidth = 0
            layer.shadowOpacity = 0
            outlineForDesktop()
            return
        }
        let ring = HQPalette.tint.resolvedColor(with: traitCollection)
        layer.shadowColor = ring.cgColor
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
        layer.borderWidth = 1
        layer.borderColor = ring.withAlphaComponent(0.1).cgColor
        layer.shadowOpacity = 0.08
        layer.shadowOffset = CGSize(width: 0, height: 10)
        layer.shadowRadius = 14
        guard !HQMotion.reduced else { layer.removeAnimation(forKey: "glow"); return }
        if Self.entered.insert(key).inserted {
            let rise = CABasicAnimation(keyPath: "transform.translation.y")   // HQMotion.reduced checked above
            rise.fromValue = 6
            rise.toValue = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.74
            fade.toValue = 1
            let enter = CAAnimationGroup()
            enter.animations = [rise, fade]
            enter.duration = 0.18
            enter.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            layer.add(enter, forKey: "enter")
        }
        guard layer.animation(forKey: "glow") == nil else { return }
        func step(_ key: String, _ from: Any, _ to: Any) -> CABasicAnimation {
            let a = CABasicAnimation(keyPath: key)   // motion-ok: inside the Reduce Motion guard above
            a.fromValue = from
            a.toValue = to
            return a
        }
        let glow = CAAnimationGroup()
        glow.animations = [step("borderColor", ring.withAlphaComponent(0.06).cgColor, ring.withAlphaComponent(0.12).cgColor),
                           step("shadowOpacity", 0.05, 0.1),
                           step("shadowOffset", CGSize(width: 0, height: 8), CGSize(width: 0, height: 12)),
                           step("shadowRadius", 12, 16)]
        glow.duration = 1.8
        glow.autoreverses = true
        glow.repeatCount = .infinity
        glow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.beginTime = CACurrentMediaTime() + 0.18
        glow.fillMode = .backwards
        layer.add(glow, forKey: "glow")
    }

    /// [mac] Stress test 2026-10-31: in the Desktop Look a code, table or link card is the editor colour on a page a
    /// shade away (14,15,18 on 13,16,22), so no card showed and a long code line simply stopped mid-word. These cards
    /// keep the look's quiet outline, as the composer and your boxes do.
    private var desktopOutlined = false
    /// [mac] Stress test 2026-10-31 #16: in the iOS look the same cards were a 4 % shade off the bot's bubble with no
    /// edge. They take the hairline an alert quote has (the bubble's own idiom); your tinted bubble's cards stand out
    /// already and keep none.
    private var bubbleOutlined = false

    private func outlineForDesktop() {
        if bubbleOutlined {
            layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
            layer.borderColor = ChatPalette.separator.resolvedColor(with: traitCollection).cgColor
        }
        guard desktopOutlined else { return }
        layer.borderWidth = 1
        layer.borderColor = ChatPalette.strokeSecondary.resolvedColor(with: traitCollection).cgColor
    }

    func configure(_ placed: PlacedBlock, mine: Bool) {
        desktopOutlined = false
        bubbleOutlined = false
        block = placed.block
        frame = placed.frame
        let isCard: Bool
        var showsLabel = false, showsCopy = false, showsBar = false, showsAlert = false
        switch placed.block {
        case .text:
            isCard = false
            backgroundColor = .clear
        case .quote(_, let alert):
            if let alert {
                isCard = true
                backgroundColor = ChatPalette.fill4
                layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
                layer.borderColor = ChatPalette.separator.resolvedColor(with: traitCollection).cgColor
                layer.cornerRadius = HQShape.radius(8, .card)
                showsLabel = true
                showsAlert = true
                let tone = alertColor(alert.title)
                label.text = alert.title
                label.font = HQFont.scaled(13, weight: .semibold, like: .footnote, cap: 22)
                label.adjustsFontForContentSizeCategory = true   // [a11y] follows a live text-size change
                label.textColor = tone
                alertIcon.image = UIImage(systemName: alert.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
                alertIcon.tintColor = tone
            } else {
                isCard = false
                backgroundColor = .clear
                showsBar = true
            }
        case .code(let lang, let code, _, _):
            isCard = true
            backgroundColor = ChatPalette.codeFill
            layer.cornerRadius = ChatMetrics.codeRadius
            layer.borderWidth = 0
            desktopOutlined = Theme.isDesktop
            bubbleOutlined = !Theme.isDesktop && !mine
            showsCopy = true
            showsLabel = lang != nil
            label.text = lang
            label.font = HQFont.scaled(12, weight: .medium, like: .caption1, cap: 20)
            label.adjustsFontForContentSizeCategory = true   // [a11y] follows a live text-size change
            label.textColor = ChatPalette.label2   // [a11y] words to read: secondary ink, not the 36 % tertiary
            copyText = code
        case .table(let table):
            isCard = true
            backgroundColor = ChatPalette.tableFill
            layer.cornerRadius = ChatMetrics.codeRadius
            layer.borderWidth = 0
            desktopOutlined = Theme.isDesktop
            bubbleOutlined = !Theme.isDesktop && !mine
            copyText = table.plain
        case .linkChip:
            isCard = true
            backgroundColor = ChatPalette.fill4
            layer.cornerRadius = HQShape.radius(12, .card)   // [mac] 2026-10-31: the look's corners, as the other cards
            layer.borderWidth = 0
            desktopOutlined = Theme.isDesktop
            bubbleOutlined = !Theme.isDesktop && !mine
        case .pageCard:
            isCard = true
            backgroundColor = ChatPalette.fill4
            layer.cornerRadius = HQShape.radius(12, .card)
            layer.borderWidth = 0
            desktopOutlined = Theme.isDesktop
            bubbleOutlined = !Theme.isDesktop && !mine
        case .spacer, .media:                     // [attachments] a media block draws in the bubble's media view
            isCard = false
            backgroundColor = .clear
        }
        if case .linkChip(let url) = placed.block {
            let view = chip ?? {
                let made = LinkChipView()
                made.onOpen = { [weak self] url in self?.onOpenLink?(url) }
                addSubview(made)
                chip = made
                return made
            }()
            view.isHidden = false
            view.frame = CGRect(origin: .zero, size: placed.frame.size)
            view.configure(url, style: ChatStyleCache.shared.style(for: traitCollection.preferredContentSizeCategory))
        } else if let chip {
            chip.isHidden = true
            chip.reset()
        }
        if case .pageCard(let ref) = placed.block {
            let view = pageCard ?? {
                let made = PageCardView()
                made.onOpen = { [weak self] ref in
                    if let url = MarkdownMedia.linkURL(ref) { self?.onOpenLink?(url) }
                }
                addSubview(made)
                pageCard = made
                return made
            }()
            view.isHidden = false
            view.frame = CGRect(origin: .zero, size: placed.frame.size)
            view.configure(ref, context: placed.pageContext, style: ChatStyleCache.shared.style(for: traitCollection.preferredContentSizeCategory))
        } else if let pageCard {
            pageCard.isHidden = true
            pageCard.reset()
        }
        if !isCard { layer.cornerRadius = 0; layer.borderWidth = 0 }
        outlineForDesktop()
        // [attachments] a media block's photos and file rows take the touches (the media view under this one)
        if case .media = placed.block { isUserInteractionEnabled = false } else { isUserInteractionEnabled = true }
        layer.cornerCurve = .continuous
        clipsToBounds = placed.codeOpen != nil || placed.grid != nil
        if let g = placed.grid {
            grid.isHidden = false
            grid.frame = CGRect(origin: .zero, size: g.size)
            grid.grid = g
        } else {
            grid.isHidden = true
        }
        label.isHidden = !showsLabel
        copyButton.isHidden = !showsCopy
        if case .table = placed.block { expandButton.isHidden = false } else { expandButton.isHidden = true }
        bar.isHidden = !showsBar
        alertIcon.isHidden = !showsAlert
        setCopyGlyph(done: false)

        let tf = placed.textFrame
        let contentSize = CGSize(width: max(tf.width, placed.contentWidth), height: max(tf.height, placed.contentHeight))
        if case .table = placed.block {
            // A table scrolls in its whole card, edge to edge.
            scroll.frame = CGRect(x: 0, y: tf.minY, width: placed.frame.width, height: tf.height)
            content.frame = CGRect(x: tf.minX, y: 0, width: placed.contentWidth, height: tf.height)
            scroll.contentSize = CGSize(width: placed.contentWidth + 2 * tf.minX, height: tf.height)
        } else {
            scroll.frame = tf
            content.frame = CGRect(origin: .zero, size: contentSize)
            scroll.contentSize = contentSize
        }
        // Sideways for wide tables and unwrapped code; up and down inside an opened code clamp.
        scroll.isScrollEnabled = placed.contentWidth > tf.width + 0.5 || (placed.codeOpen == true && placed.contentHeight > tf.height + 0.5)
        // A table's edge fades say it goes on; the system's bar would sit on its last row.
        let isTable: Bool = { if case .table = placed.block { return true } else { return false } }()
        scroll.showsHorizontalScrollIndicator = !isTable && scroll.isScrollEnabled && placed.contentWidth > tf.width + 0.5
        scroll.contentOffset = .zero
        setPieces(placed.pieces, width: placed.layoutWidth)

        // The code clamp: a fade over the code area's bottom and a 44 pt chevron toggle at its trailing end.
        if let open = placed.codeOpen {
            // The fade turns solid in its lower half, where the chevron sits, so no code shows under the glyph.
            fadeView.isHidden = open
            fadeView.frame = CGRect(x: 0, y: placed.frame.height - ChatMetrics.codeFade, width: placed.frame.width, height: ChatMetrics.codeFade)
            toggleButton.isHidden = false
            // A 44 pt target whose glyph centres in the fade's solid bottom.
            toggleButton.frame = CGRect(x: placed.frame.width - 4 - 44, y: placed.frame.height - 44, width: 44, height: 44)
            var config = toggleButton.configuration
            config?.contentInsets = NSDirectionalEdgeInsets(top: open ? 0 : 18, leading: 0, bottom: 0, trailing: 0)
            config?.image = UIImage(systemName: open ? "chevron.up" : "chevron.down",
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
            toggleButton.configuration = config
            toggleButton.accessibilityLabel = open ? "Show Less Code" : "Show All Code"
        } else {
            fadeView.isHidden = true
            toggleButton.isHidden = true
        }
        // Your clamped message: its last visible line fades out.
        if placed.fadesBottom, tf.height > 0 {
            let fade = min(tf.height, ChatStyleCache.shared.style(for: traitCollection.preferredContentSizeCategory).bodyLineHeight)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            bottomMask.frame = CGRect(origin: .zero, size: placed.frame.size)
            let start = Double(max(0, tf.height - fade) / max(1, placed.frame.height))
            bottomMask.locations = [0, NSNumber(value: start), NSNumber(value: Double(tf.height / max(1, placed.frame.height)))]
            CATransaction.commit()
            layer.mask = bottomMask
        } else if layer.mask != nil {
            layer.mask = nil
        }

        if showsLabel {
            if showsAlert {
                alertIcon.frame = CGRect(x: 10, y: 10, width: 14, height: 16)
                label.frame = CGRect(x: 30, y: 10, width: bounds.width - 40, height: ceil(label.font.lineHeight))
            } else {
                label.frame = CGRect(x: 14, y: 0, width: max(0, bounds.width - 72), height: ChatMetrics.codeStrip)
            }
        }
        if showsCopy { copyButton.frame = CGRect(x: bounds.width - 4 - 44, y: 0, width: 44, height: 44) }
        if case .table(let table) = placed.block {
            // Under the grid, the card's width; its touch area at least 44 pt tall, reaching past the card's bottom.
            let footer = placed.frame.height - tf.maxY
            expandButton.configure(rows: table.rows.count, columns: table.columnCount, footerHeight: footer)
            expandButton.frame = CGRect(x: 0, y: tf.maxY, width: bounds.width, height: max(44, footer))
        }
        updateEdgeFade()
        if showsBar { bar.frame = CGRect(x: 0, y: 2, width: 2, height: max(0, bounds.height - 4)) }
    }

    // MARK: Pieces

    private func setPieces(_ new: [TextPiece], width: CGFloat?) {
        let same = new.count == pieces.count && width == layoutWidth && zip(new, pieces).allSatisfy { $0.text === $1.text && $0.frame == $1.frame }
        pieces = new
        layoutWidth = width
        if !same {
            findMarks = [:]
            selectionMarks = [:]   // [mac] the cell's selection draws again on the new pieces (`ChatTextSelector.refresh`)
            for (_, view) in pieceViews { park(view) }
            pieceViews.removeAll()
        }
        updateVisiblePieces()
    }

    /// The screen's visible area, in this view's coordinates (from the cell, as the table scrolls), so pieces far
    /// from the screen give up their views and drawings.
    // MARK: Find in chat

    /// Each piece's matches (by piece index), drawn by its view while it has one.
    private var findMarks: [Int: [TextDrawView.FindMark]] = [:]

    /// Marks every occurrence of `query` in this block's text; the `current`-th (counted across its pieces) in the
    /// current colour. Returns how many occurrences the block holds (the bubble counts across its blocks).
    @discardableResult
    func setFind(_ query: String?, current: Int?) -> Int {
        var marks: [Int: [TextDrawView.FindMark]] = [:]
        var count = 0
        if let query, !ChatFind.normalized(query).isEmpty {
            for (i, piece) in pieces.enumerated() {
                // [transcript] A flag in inline code is drawn with word joiners (L307): the search looks past them.
                let ranges = InlineCodeText.findRanges(of: query, in: piece.text.string)
                guard !ranges.isEmpty else { continue }
                marks[i] = ranges.map { range in
                    defer { count += 1 }
                    return TextDrawView.FindMark(range: range, current: count == current)
                }
            }
        }
        findMarks = marks
        for (i, view) in pieceViews { view.findHighlights = marks[i] ?? [] }
        return count
    }

    /// Where the current match sits in this view's coordinates (nil when it isn't in this block).
    func currentFindRect() -> CGRect? {
        for (i, marks) in findMarks {
            guard let mark = marks.first(where: \.current), pieces.indices.contains(i) else { continue }
            let piece = pieces[i]
            let layout = pieceViews[i]?.textKit ?? TextKitPool.layout(piece.text, width: layoutWidth)
            guard let box = layout.rects(for: mark.range).first else { return nil }
            return content.convert(box.offsetBy(dx: piece.frame.minX, dy: piece.frame.minY), to: self)
        }
        return nil
    }

    func setWindowRect(_ rect: CGRect?) {
        windowRect = rect
        if pieces.count > 1 { updateVisiblePieces() }
    }

    private func updateVisiblePieces() {
        var region = scroll.bounds.insetBy(dx: 0, dy: -600)
        if let windowRect {
            let inContent = convert(windowRect, to: content).insetBy(dx: 0, dy: -600)
            region = region.intersection(inContent)
        }
        for (i, piece) in pieces.enumerated() {
            let wanted = pieces.count == 1 || piece.frame.intersects(region)
            if wanted, pieceViews[i] == nil {
                let view = spareViews.popLast() ?? TextDrawView()
                if view.superview !== content { content.addSubview(view) }
                view.isHidden = false
                view.frame = piece.frame
                view.set(piece.text, width: layoutWidth)
                view.findHighlights = findMarks[i] ?? []
                view.selectionColor = selectionTint
                view.selection = selectionMarks[i]   // after `set`, which drops a selection
                view.setNeedsDisplay()
                pieceViews[i] = view
            } else if !wanted, let view = pieceViews[i] {
                park(view)
                pieceViews[i] = nil
            }
        }
    }

    private func park(_ view: TextDrawView) {
        view.findHighlights = []
        view.selection = nil
        view.isHidden = true
        view.layer.contents = nil
        spareViews.append(view)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if pieces.count > 1 { updateVisiblePieces() }
        updateEdgeFade()
    }

    /// A table wider than its card fades out over 28 pt at an edge with more columns past it (the trailing one at
    /// first, the leading one once scrolled), so a column cut by the edge reads as going on, not as cut off.
    /// [mac] Stress test 2026-10-31: unwrapped code wider than its card too; its line stopped mid-letter at the edge,
    /// beside the copy button, and read as cut off.
    private func updateEdgeFade() {
        let fades: Bool = switch block { case .table?, .code?: true; default: false }
        guard fades, scroll.contentSize.width > scroll.bounds.width + 0.5 else {
            if scroll.layer.mask != nil { scroll.layer.mask = nil }
            return
        }
        let width = max(1, scroll.bounds.width)
        let x = scroll.contentOffset.x
        let fade = min(28, width / 4) / width
        let before: CGFloat = x > 0.5 ? 1 : 0
        let after: CGFloat = x < scroll.contentSize.width - scroll.bounds.width - 0.5 ? 1 : 0
        let solid = UIColor.black.cgColor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        edgeFade.frame = scroll.bounds   // the mask sits in the scroll's bounds, which move as it scrolls
        edgeFade.colors = [UIColor.black.withAlphaComponent(1 - before).cgColor, solid, solid,
                           UIColor.black.withAlphaComponent(1 - after).cgColor]
        edgeFade.locations = [0, NSNumber(value: Double(fade)), NSNumber(value: Double(1 - fade)), 1]
        CATransaction.commit()
        if scroll.layer.mask !== edgeFade { scroll.layer.mask = edgeFade }
    }

    // MARK: Actions

    private func alertColor(_ title: String) -> UIColor {
        switch title {
        case "Tip": return .systemGreen
        case "Important": return .systemPurple
        case "Warning": return .systemOrange
        case "Caution": return .systemRed
        default: return .systemBlue
        }
    }

    private func setCopyGlyph(done: Bool) {
        var config = copyButton.configuration
        config?.image = UIImage(systemName: done ? "checkmark" : "doc.on.doc",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        copyButton.configuration = config
    }

    @objc private func expandTable() {
        guard case .table(let table)? = block else { return }
        onExpandTable?(table)
    }

    /// [transcript] A tap on a table's cells opens the Table page too (a link or inline code under the tap wins: the
    /// bubble asks those first).
    func expandTableIfHit(_ point: CGPoint) -> Bool {
        guard case .table(let table)? = block, !table.rows.isEmpty, !isHidden, bounds.contains(point) else { return false }
        expandTable()
        return true
    }

    @objc private func copyCode() {
        UIPasteboard.general.string = copyText
        Haptics.play(.success)
        setCopyGlyph(done: true)
        copyResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.setCopyGlyph(done: false) }
        copyResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    @objc private func toggleCode() {
        Haptics.play(.selection)
        onToggleCode?()
    }

    /// A link under a point in this block's coordinates.
    func link(at point: CGPoint) -> URL? {
        for (_, view) in pieceViews where !view.isHidden {
            let p = convert(point, to: view)
            if view.bounds.insetBy(dx: -6, dy: -6).contains(p), let url = view.link(at: p) { return url }
        }
        return nil
    }

    /// [transcript] The link a hold at this point is on: the link chip's page, or a link in the text.
    func heldLink(at point: CGPoint) -> URL? {
        if let chip, !chip.isHidden, chip.frame.contains(point), let url = chip.url { return url }
        // [pins] A held page card: its own menu (Open, Pin, Share…, Copy Path), not the message's.
        if let pageCard, !pageCard.isHidden, pageCard.frame.contains(point), let url = pageCard.link { return url }
        return link(at: point)
    }

    /// What one tap here copies: the inline code under the point, or a whole code card (Telegram copies a code block
    /// on a tap; the card's own buttons keep their taps).
    func copyable(at point: CGPoint) -> String? {
        if case .code? = block, bounds.contains(point), !copyText.isEmpty { return copyText }
        for (_, view) in pieceViews where !view.isHidden {
            let p = convert(point, to: view)
            if view.bounds.insetBy(dx: -6, dy: -6).contains(p), let text = view.copyable(at: p) { return text }
        }
        return nil
    }

    /// The code card's Copy glyph turns into a check, as when its button is pressed.
    func showCopied() {
        guard case .code? = block else { return }
        setCopyGlyph(done: true)
        copyResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.setCopyGlyph(done: false) }
        copyResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// [mac] The text pieces on screen in reading order, for selecting with the mouse.
    var drawnPieces: [TextDrawView] {
        pieceViews.sorted { $0.key < $1.key }.map(\.value).filter { !$0.isHidden && $0.textKit != nil }
    }

    /// The text views' texts for prefetching layouts.
    var pieceTexts: [TextPiece] { pieces }

    // MARK: [mac] Selecting with the mouse (Mac audit #11, ChatTextSelection.swift)

    /// Draws `marks` (each piece's selected range, by piece index) under the text in `color`; empty clears it.
    func showSelection(_ marks: [Int: NSRange], color: UIColor) {
        selectionTint = color
        guard marks != selectionMarks else { return }
        selectionMarks = marks
        for (i, view) in pieceViews {
            view.selectionColor = color
            view.selection = marks[i]
        }
    }

    /// The caret position nearest a point in this view's coordinates: the nearest piece, then its nearest character.
    /// Nil for a block without text (a link chip, a page card).
    func selectionSpot(at point: CGPoint) -> (piece: Int, offset: Int)? {
        let p = convert(point, to: content)
        guard let i = SelectionGeometry.nearest(p, in: pieces.map(\.frame)) else { return nil }
        let piece = pieces[i]
        let layout = pieceViews[i]?.textKit ?? TextKitPool.layout(piece.text, width: layoutWidth)
        return (i, layout.insertionIndex(at: CGPoint(x: p.x - piece.frame.minX, y: p.y - piece.frame.minY)))
    }

    /// Where the block's text is drawn, in its own coordinates (null for a block without text), cut to what shows of
    /// a clamped code card.
    var selectionTextBounds: CGRect {
        let text = pieces.reduce(CGRect.null) { $0.union($1.frame) }
        return text.isNull ? text : content.convert(text, to: self).intersection(scroll.frame)
    }

    /// Whether a point in this view's coordinates is on its selected words.
    func isOnSelection(_ point: CGPoint) -> Bool {
        let p = convert(point, to: content)
        for (i, range) in selectionMarks where pieces.indices.contains(i) {
            let piece = pieces[i]
            let layout = pieceViews[i]?.textKit ?? TextKitPool.layout(piece.text, width: layoutWidth)
            let local = CGPoint(x: p.x - piece.frame.minX, y: p.y - piece.frame.minY)
            if layout.rects(for: range).contains(where: { $0.insetBy(dx: -2, dy: -2).contains(local) }) { return true }
        }
        return false
    }

    #if DEBUG
    /// MacShots: the ranges marked, by piece, and the ranges the piece views draw.
    var debugSelectionMarks: [Int: NSRange] { selectionMarks }
    var debugDrawnSelections: [Int: NSRange] { pieceViews.compactMapValues(\.selection) }
    #endif
}

/// A vertical fade from clear to `color` (the code clamp's bottom), solid over its lower half, resolved for the
/// current appearance.
final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    var color: UIColor = .clear { didSet { apply() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: GradientView, _) in view.apply() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func apply() {
        let resolved = color.resolvedColor(with: traitCollection)
        let gradient = layer as! CAGradientLayer
        gradient.colors = [resolved.withAlphaComponent(0).cgColor, resolved.cgColor, resolved.cgColor]
        gradient.locations = [0, 0.55, 1]
    }
}

/// [transcript] The table card's footer: a hairline over "7 rows · 4 columns" and, at the trailing end, "⤢ Expand" in
/// the tint. The whole row is the button (owner 2026-10-29: the old glyph on the header row sat on the cells' words).
/// The row count goes when the card is too narrow for both. A button, so its tap wins over the bubble's own tap.
final class TableFooterControl: UIButton {
    private let rule = UIView()
    private let count = UILabel()
    private let glyph = UIImageView()
    private let word = UILabel()
    private var footerHeight: CGFloat = 36

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        rule.backgroundColor = ChatPalette.separator
        rule.isUserInteractionEnabled = false
        addSubview(rule)
        for label in [count, word] {
            label.adjustsFontForContentSizeCategory = true   // [a11y] follows a live text-size change
            label.isUserInteractionEnabled = false
            addSubview(label)
        }
        count.font = HQFont.scaled(12, weight: .regular, like: .caption1, cap: 20)
        count.textColor = ChatPalette.label2
        word.font = HQFont.scaled(12, weight: .semibold, like: .caption1, cap: 20)
        word.textColor = ChatPalette.tintText
        word.text = "Expand"
        glyph.tintColor = ChatPalette.tintText
        glyph.contentMode = .center
        glyph.isUserInteractionEnabled = false
        addSubview(glyph)
        setGlyph()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: TableFooterControl, _) in view.setGlyph() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var long = "", short = ""
    /// A table still arriving shows its header before any row: its footer stays (so nothing jumps when the rows come)
    /// but says nothing and expands nothing until the first row ("0 rows · Expand" opened an empty table: Mac polish #75).
    private var hasRows = true

    func configure(rows: Int, columns: Int, footerHeight: CGFloat) {
        self.footerHeight = footerHeight
        short = "\(rows) \(rows == 1 ? "row" : "rows")"
        long = "\(short) · \(columns) \(columns == 1 ? "column" : "columns")"
        accessibilityValue = long.replacingOccurrences(of: " · ", with: ", ")
        hasRows = rows > 0
        isEnabled = hasRows
        isAccessibilityElement = hasRows
        word.isHidden = !hasRows
        glyph.isHidden = !hasRows
        setNeedsLayout()
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? ChatPalette.fill3 : .clear }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let hairline = 1 / max(traitCollection.displayScale, 1)
        rule.frame = CGRect(x: 0, y: 0, width: bounds.width, height: hairline)
        let pad = ChatMetrics.tableCellPadH + 2
        let mid = (footerHeight / 2).rounded()
        let wordSize = word.sizeThatFits(CGSize(width: bounds.width, height: footerHeight))
        let glyphSize = glyph.image?.size ?? .zero
        let wordX = bounds.width - pad - ceil(wordSize.width)
        word.frame = CGRect(x: wordX, y: mid - ceil(wordSize.height) / 2, width: ceil(wordSize.width), height: ceil(wordSize.height))
        glyph.frame = CGRect(x: wordX - 5 - ceil(glyphSize.width), y: mid - ceil(glyphSize.height) / 2,
                             width: ceil(glyphSize.width), height: ceil(glyphSize.height))
        // "7 rows · 4 columns", or "7 rows" on a narrow card, or nothing.
        let room = glyph.frame.minX - 12 - pad
        count.text = long
        if ceil(count.sizeThatFits(CGSize(width: bounds.width, height: footerHeight)).width) > room { count.text = short }
        let countSize = count.sizeThatFits(CGSize(width: bounds.width, height: footerHeight))
        count.isHidden = !hasRows || ceil(countSize.width) > room
        count.frame = CGRect(x: pad, y: mid - ceil(countSize.height) / 2, width: max(0, room), height: ceil(countSize.height))
    }

    private func setGlyph() {
        glyph.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right",
                              withConfiguration: UIImage.SymbolConfiguration(font: word.font, scale: .small))
        setNeedsLayout()
    }
}

/// A table's header band and row lines (spec 03 §9.5: the header row muted), drawn under its cells.
final class TableGridView: UIView {
    var grid: TableGrid? { didSet { if grid != oldValue { setNeedsDisplay() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: TableGridView, _) in view.setNeedsDisplay() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        guard let grid, grid.rows.count >= 2, let ctx = UIGraphicsGetCurrentContext() else { return }
        let width = bounds.width
        ChatPalette.tableHead.resolvedColor(with: traitCollection).setFill()
        ctx.fill(CGRect(x: 0, y: grid.rows[0], width: width, height: grid.rows[1] - grid.rows[0]))
        let hairline = 1 / max(traitCollection.displayScale, 1)
        ChatPalette.separator.resolvedColor(with: traitCollection).setFill()
        for y in grid.rows.dropFirst().dropLast() {
            ctx.fill(CGRect(x: 0, y: y - hairline / 2, width: width, height: hairline))
        }
    }
}


#if DEBUG
extension TextDrawView {
    /// [a11y] UI tests: the font the first run of this view's text is really drawn with, and the text's natural width.
    var debugFirstFont: UIFont? {
        guard let text, text.length > 0 else { return nil }
        return text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
    }
    var debugTextLength: Int { text?.length ?? 0 }
    var debugNaturalWidth: CGFloat {
        guard let text else { return 0 }
        return ceil(text.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                      options: [.usesLineFragmentOrigin], context: nil).width)
    }
}
#endif
