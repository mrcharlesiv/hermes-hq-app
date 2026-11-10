import UIKit

// Table cells for the chat. Every frame comes from the precomputed `RowLayout` (no Auto Layout inside cells), and each
// cell's contentView is flipped back upright inside the inverted table.

@MainActor protocol ChatCellDelegate: AnyObject {
    /// A tool run, a thought, or your clamped message's Show More.
    func chatCellToggle(rowId: String)
    /// A code block's clamp toggle (block index inside the bubble).
    func chatCellToggleCode(rowId: String, block: Int)
    func chatCellOpenStep(rowId: String, index: Int)
    func chatCellOpen(url: URL)
    /// [transcript] A link held in a bubble or a link chip: its own menu (Open, Open in Safari, Copy Link, Share…), titled
    /// with the whole address (docs/spec/3x-transcript.md L492, L568); nil keeps the message's menu.
    func chatCellLinkMenu(url: URL, source: UIView) -> UIMenu?
    /// A long opened One Line card's "Show All N Steps": the reply's Steps sheet.
    func chatCellShowAllSteps(rowId: String)
    /// The thinking row tapped: the running turn's steps, in the Steps sheet.
    func chatCellShowLiveSteps()
    /// "Delivery Unconfirmed · Check" under your message.
    func chatCellCheckDelivery(rowId: String)
    /// The error card's ✕ and Details (spec 06 §5.6.1).
    func chatCellDismissError(rowId: String)
    func chatCellErrorDetails(rowId: String, details: String)
    /// "Stopped before <Bot> replied" › Retry and the error card's Retry: send that prompt again (spec 06 §5.6.1, §5.6.3).
    func chatCellRetry(rowId: String)
    /// [transcript] An error card's "Choose a Model".
    func chatCellChooseModel()
    /// MENUS (spec 1x §9): the hold menu for the message a bubble belongs to; nil keeps the cell's own Copy.
    func chatCellMenu(rowId: String, source: UIView) -> UIMenu?
    /// A folded row's hold menu (a delivery, a finished subagent or task, a tool row); nil: no menu.
    func chatCellRowMenu(rowId: String, source: UIView) -> UIMenu?
    /// MENUS: the latest reply's action row — whether it offers Regenerate, its More menu (nil: none), and Regenerate.
    var chatCellOffersRegenerate: Bool { get }
    func chatCellReplyMore(rowId: String, source: UIView) -> UIMenu?
    func chatCellRegenerate(rowId: String)
    /// [talk] Read Aloud on the latest reply's action row (docs/spec/3x-talk.md §7.1): nil where it is not offered.
    func chatCellReadAloud(rowId: String) -> ReadAloudCenter.Button?
    func chatCellToggleReadAloud(rowId: String)
    /// [transcript] A table's expand button: the Table sheet (docs/spec/3x-transcript.md §3.4).
    func chatCellOpenTable(_ table: MarkdownTable)
    /// Your Tapback badge tapped: it comes off (with Message Reactions on).
    func chatCellRemoveReaction(rowId: String)
    /// Swipe to Reply: whether a bot's bubble can be replied to here, and the reply begun (a quote over the composer).
    func chatCellCanReply(rowId: String) -> Bool
    func chatCellReply(rowId: String)
}

extension ChatCellDelegate {
    func chatCellLinkMenu(url: URL, source: UIView) -> UIMenu? { nil }
    func chatCellShowAllSteps(rowId: String) {}
    func chatCellShowLiveSteps() {}
    func chatCellOpenTable(_ table: MarkdownTable) {}
    func chatCellRemoveReaction(rowId: String) {}
    func chatCellCanReply(rowId: String) -> Bool { false }
    func chatCellReply(rowId: String) {}
    func chatCellReadAloud(rowId: String) -> ReadAloudCenter.Button? { nil }
    func chatCellToggleReadAloud(rowId: String) {}
    func chatCellMenu(rowId: String, source: UIView) -> UIMenu? { nil }
    func chatCellRowMenu(rowId: String, source: UIView) -> UIMenu? { nil }
    var chatCellOffersRegenerate: Bool { false }
    func chatCellReplyMore(rowId: String, source: UIView) -> UIMenu? { nil }
    func chatCellRegenerate(rowId: String) {}
}

class ChatBaseCell: UITableViewCell {
    weak var delegate: ChatCellDelegate?
    var rowId = ""

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
        clipsToBounds = false
        contentView.clipsToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// [backdrop] Theme › Chat Background: a frosted pill under a line drawn straight on the page (a day, a notice, a
    /// tool run), so the grey words stay readable on the picture. Made the first time a background is on; hidden
    /// without one, so a chat with no picture draws exactly as before. Frosted, not glass (owner, 2026-11-01: "more flat
    /// in some way. Just so it's not ALL glass", then "I like frosted the most"): the glass bubbles stand out and the
    /// lines between them stay flat. The system's thin material has no rim or shine, reads on a busy picture, and goes
    /// solid by itself under Reduce Transparency. The Mac takes the next material up: its thin one let "From Ivy · 2 more"
    /// fall to 4.46:1 over Sunset (5.05:1 now).
    private var backing: UIVisualEffectView?

    /// `rect` in the content view's space; nil hides the pill.
    func placeBacking(_ rect: CGRect?, radius: CGFloat) {
        guard let rect, !rect.isEmpty, Backdrop.chats.shows else {
            backing?.isHidden = true
            return
        }
        let pill = backing ?? {
            let made = UIVisualEffectView(effect: UIBlurEffect(style: DeviceWord.isMac ? .systemMaterial : .systemThinMaterial))
            made.isUserInteractionEnabled = false
            made.isAccessibilityElement = false
            made.clipsToBounds = true
            contentView.insertSubview(made, at: 0)
            backing = made
            return made
        }()
        pill.isHidden = false
        pill.frame = rect
        pill.cornerConfiguration = .corners(radius: .fixed(min(radius, rect.height / 2)))
        pill.contentView.backgroundColor = .clear
    }

    /// Whether the line has its pill (a press then shades the pill rather than the row's own highlight).
    var showsBacking: Bool { backing.map { !$0.isHidden } ?? false }

    /// [backdrop] A card of content under a line (an opened run, a group's members): the faint page fill with no
    /// picture, the reply bubble's own colour on one (the faint fill all but vanished there; content stays on solid cards).
    static var contentCardFill: UIColor { Backdrop.chats.shows ? ChatPalette.botBubble : ChatPalette.fill4 }

    /// A press on a line with a pill: the pill takes the row's press shade, so the pressed shape is the pill's.
    func pressBacking(_ on: Bool) {
        guard let backing else { return }
        if on {
            backing.contentView.backgroundColor = ChatPalette.fill4
        } else {
            UIView.animate(withDuration: 0.2) { backing.contentView.backgroundColor = .clear }   // motion-ok: colour only
        }
    }

    #if targetEnvironment(macCatalyst)
    /// [mac] The pointer over a line with a pill: the pill takes the list rows' hover fill (`MacHover.rowFill`).
    func hoverBacking(_ on: Bool) {
        backing?.contentView.backgroundColor = on ? MacHover.rowFill : .clear
    }
    #endif

    /// [m9/ipad] In a pane wider than the readable column (760 pt) the row's content is laid out for the column and
    /// sits centred in the pane; the cell still spans the pane, so the margins scroll the transcript too.
    override func layoutSubviews() {
        super.layoutSubviews()
        applyContentShift()
    }

    /// Swipe to Reply: how far the row's content is slid left of its place (0 at rest).
    var slideLeft: CGFloat = 0 { didSet { if slideLeft != oldValue { applyContentShift() } } }

    private func applyContentShift() {
        let x = slideLeft - ReadableColumn.fit(pane: bounds.width).margin
        if contentView.bounds.origin.x != x { contentView.bounds.origin.x = x }
    }

    func configure(_ row: ChatRow, layout: RowLayout) { rowId = row.id }

    // [talk] The reply being read aloud carries a 3 pt tint bar at its leading edge that pulses every 1.4 s (steady
    // under Reduce Motion). A decoration: it never changes the row's height (docs/spec/3x-talk.md §7.5).
    private var spokenBar: UIView?

    func setSpoken(_ spoken: Bool) {
        guard spoken != (spokenBar != nil) else { return }
        guard spoken else {
            spokenBar?.removeFromSuperview()
            spokenBar = nil
            return
        }
        let bar = UIView(frame: CGRect(x: 5, y: 2, width: 3, height: max(0, contentView.bounds.height - 4)))
        bar.autoresizingMask = [.flexibleHeight]
        bar.backgroundColor = tintColor
        bar.layer.cornerRadius = 1.5
        bar.isUserInteractionEnabled = false
        bar.accessibilityIdentifier = "chat.spoken-bar"
        bar.isAccessibilityElement = true
        bar.accessibilityLabel = "Being read aloud"
        contentView.addSubview(bar)
        spokenBar = bar
        guard !HQMotion.reduced else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.55
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bar.layer.add(pulse, forKey: "pulse")
    }

    /// The table scrolled: a tall cell lets the text far from the screen give up its drawing.
    func updateWindowRect(in table: UITableView) {}

    override func prepareForReuse() {
        super.prepareForReuse()
        // A send lift hides the real row while its stand-in flies (ChatViewController, spec 06 §5.2).
        contentView.isHidden = false
        setSpoken(false)   // [talk]
    }
}

// MARK: - Bubble

final class BubbleShapeView: UIView {
    override class var layerClass: AnyClass { CAShapeLayer.self }
    var shapeLayer: CAShapeLayer { layer as! CAShapeLayer }
    var fill: UIColor = ChatPalette.botBubble { didSet { updateFill() } }
    /// A reply's text bubble (not a tool card): the one High Contrast boxes in the Desktop Look.
    var isReply = false { didSet { if isReply != oldValue { updateFill() } } }
    /// The outline, from the row's layout. [glass-bubbles] Set here rather than on the layer: glass draws it without the
    /// tail.
    var key: BubbleShape.Key? { didSet { updatePath() } }   // every time: Bubble Corners may have changed the outline
    /// [glass-bubbles] False for the send's flying stand-in: its reveal mask would cut the glass flat (it lands solid
    /// for the moment the real row takes over). [tinted-bubbles] The tint too: the stand-in is outside the chat's
    /// background.
    var allowsGlass = true { didSet { if allowsGlass != oldValue { updateFill() } } }
    /// [glass-bubbles] The Liquid Glass bubble (`GlassBubbles`), made on first use, and the Increase Contrast edge drawn
    /// over it.
    private var glass: UIVisualEffectView?
    private var glassTint: UIColor?
    /// [reply-backing] The glass's corners as last set (top left, top right, bottom left, bottom right).
    private var glassCorners: [CGFloat] = []
    private var edge: CAShapeLayer?
    private var drawsGlass = false
    /// [tinted-bubbles] The bubble's colour over its slice of the Chat Background's soft copy (`TintedBubbles`), made
    /// on first use, and the chat's background it lines up with.
    private var tint: TintedBubbleLayer?
    private var tintAspect = CGSize.zero
    private weak var tintAnchor: BackdropView?
    private var anchorLooked = false
    private var drawsTint = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self, UITraitAccessibilityContrast.self]) { (view: BubbleShapeView, _) in
            view.updateFill()
        }
        // [glass-bubbles] Reduce Transparency turns the glass back into the solid fill.
        NotificationCenter.default.addObserver(self, selector: #selector(accessibilityChanged), name: HQAccessibility.didChange, object: nil)
        // [tinted-bubbles] A Chat Background picked, removed or dimmed, or its picture made: the tint follows.
        NotificationCenter.default.addObserver(self, selector: #selector(backdropChanged), name: Backdrop.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(backdropChanged), name: Backdrop.pictureReady, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func accessibilityChanged() { updateFill() }

    @objc private func backdropChanged() {
        guard drawsTint || ThemeTable.bubbleStyle == .tinted else { return }
        updateFill()
    }

    private var wantsGlass: Bool { allowsGlass && GlassBubbles.applies }

    /// [tinted-bubbles] Picked and possible, and the bubble stands in a chat (its background is found once it's in a
    /// window).
    private var wantsTint: Bool {
        guard allowsGlass, TintedBubbles.applies, window != nil else { return false }
        if !anchorLooked {
            anchorLooked = true
            tintAnchor = TintedBubbles.anchor(for: self)
        }
        return tintAnchor != nil
    }

    private func updatePath() {
        guard let key else { shapeLayer.path = nil; return }
        shapeLayer.path = BubbleShape.path(drawsGlass ? key.withoutTail : key)
        if drawsGlass { shapeGlass(key) }
        if drawsTint {
            tint?.outline.path = shapeLayer.path
            edge?.path = shapeLayer.path
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeGlass()
        edge?.frame = bounds
        if drawsTint {
            tint?.frame = bounds
            alignTint()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // [tinted-bubbles] A new place may have another chat's background behind it, or none.
        anchorLooked = false
        tintAnchor = nil
        if window != nil, drawsTint || ThemeTable.bubbleStyle == .tinted { updateFill() }
        placeGlass()   // [reply-backing] the screen it stands in
    }

    /// [tinted-bubbles] Lays the soft copy over the chat's background as it fills the chat, in this bubble's terms: the
    /// bubble shows the slice behind it.
    func alignTint() {
        guard drawsTint, let tint, let anchor = tintAnchor else { return }
        let rect = anchor.convert(TintedBubbles.fillRect(tintAspect, in: anchor.bounds), to: self)
        if tint.copy.frame != rect { tint.copy.frame = rect }
    }

    /// [tinted-bubbles] The bubble's own copy of the picture (its lightness, the picture's colours, as far as the words
    /// allow); nil if the picture isn't made yet (the bubble is solid until `Backdrop.pictureReady`).
    private func applyTint() -> Bool {
        guard let soft = TintedBubbles.soft(for: traitCollection) else { return false }
        let mine = fill == ChatPalette.meBubble
        let contrast = traitCollection.accessibilityContrast == .high || HQAccessibility.overrides.contrast
        guard let image = TintedBubbles.image(soft, picture: Backdrop.chats.picture(for: traitCollection), bubble: fill, mine: mine,
                                              increaseContrast: contrast, traits: traitCollection) else { return false }
        shapeLayer.fillColor = UIColor.clear.cgColor
        shapeLayer.lineWidth = 0
        shapeLayer.strokeColor = nil
        let layer = tint ?? {
            let made = TintedBubbleLayer()
            self.layer.insertSublayer(made, at: 0)
            tint = made
            return made
        }()
        layer.isHidden = false
        layer.frame = bounds
        layer.outline.path = shapeLayer.path
        if (layer.copy.contents as AnyObject?) !== image { layer.copy.contents = image }
        tintAspect = soft.aspect
        drawEdge(contrast: contrast, mine: mine)
        return true
    }

    /// [glass-bubbles] The glass in the outline's corners (glass takes rounded corners, not a path: the tail's corner
    /// rounds as a joined one), tinted with the bubble's colour at the time the trait collection resolves it.
    private func applyGlass() {
        shapeLayer.fillColor = UIColor.clear.cgColor
        shapeLayer.lineWidth = 0
        shapeLayer.strokeColor = nil
        let view = glass ?? {
            let made = UIVisualEffectView()
            made.isUserInteractionEnabled = false
            made.isAccessibilityElement = false
            made.frame = bounds
            insertSubview(made, at: 0)
            glass = made
            return made
        }()
        view.isHidden = false
        let mine = fill == ChatPalette.meBubble
        let contrast = traitCollection.accessibilityContrast == .high || HQAccessibility.overrides.contrast
        let isDark = traitCollection.userInterfaceStyle == .dark
        let ownTint = ThemeTable.withSet(generation: traitCollection[ThemeGenerationTrait.self]) { $0.tokens(dark: isDark).ownLook?.replyGlassTint }
        let tint = GlassBubbles.tint(fill.resolvedColor(with: traitCollection), mine: mine, increaseContrast: contrast,
                                     replyTint: ownTint.map { CGFloat($0) })
        if tint != glassTint || view.effect == nil {
            glassTint = tint
            let effect = UIGlassEffect(style: .regular)
            effect.tintColor = tint
            view.effect = effect
        }

        if let key { shapeGlass(key) }
        drawEdge(contrast: contrast, mine: mine)
    }

    /// The line over glass or the tint: Increase Contrast's solid-bubble edge (spec 06 §1.2), else a skin's faint line
    /// round a reply (`replyLine`), else none.
    private func drawEdge(contrast: Bool, mine: Bool) {
        let colour = contrast
            ? (mine ? UIColor(white: 0, alpha: 0.3) : ChatPalette.label3).resolvedColor(with: traitCollection) : replyLine
        guard let colour else {
            edge?.isHidden = true
            return
        }
        let line = edge ?? {
            let made = CAShapeLayer()
            made.fillColor = nil
            layer.addSublayer(made)
            edge = made
            return made
        }()
        line.isHidden = false
        line.frame = bounds
        line.path = shapeLayer.path
        line.lineWidth = contrast ? 1 : replyLineWidth
        line.strokeColor = colour.cgColor
    }

    /// [rose-pine] The faint line a skin's own look draws round a reply (owner 2026-11-02: "the chat bubbles have like
    /// a little faint line around them"); nil for your messages and for every other skin.
    private var replyLine: UIColor? {
        guard fill == ChatPalette.botBubble else { return nil }
        let colour = ChatPalette.replyEdge.resolvedColor(with: traitCollection)
        return colour.cgColor.alpha > 0 ? colour : nil
    }
    /// Two device pixels: one (a code card's hairline) all but vanished against the glass's own rim.
    private var replyLineWidth: CGFloat { 2 / max(traitCollection.displayScale, 1) }

    /// [tinted-bubbles] Whether the tint draws; the chat lines it up on every scroll step while it does.
    private func setTinted(_ on: Bool) {
        if !on { tint?.isHidden = true }
        guard on != drawsTint else { return }
        drawsTint = on
        TintedBubbles.track(self, on)
    }

    private func shapeGlass(_ key: BubbleShape.Key) {
        guard glass != nil else { return }
        glassCorners = []   // the outline changed: set the corners again
        placeGlass()
        edge?.path = shapeLayer.path
    }

    /// [reply-backing] The glass over the whole bubble, or over a bubble taller than the screen only its part on screen
    /// (`GlassBubbles.slice`), square where it is cut off screen. The chat calls this on every scroll step.
    func placeGlass() {
        guard drawsGlass, let glass, let key else { return }
        let slice = GlassBubbles.slice(bubble: bounds, shown: window.map { $0.convert($0.bounds, to: self) })
        if glass.frame != slice.rect { glass.frame = slice.rect }
        let c = GlassBubbles.corners(key)
        let corners = [slice.cutTop ? 0 : c.topLeft, slice.cutTop ? 0 : c.topRight,
                       slice.cutBottom ? 0 : c.bottomLeft, slice.cutBottom ? 0 : c.bottomRight]
        guard corners != glassCorners else { return }
        glassCorners = corners
        glass.cornerConfiguration = .corners(topLeftRadius: .fixed(corners[0]), topRightRadius: .fixed(corners[1]),
                                             bottomLeftRadius: .fixed(corners[2]), bottomRightRadius: .fixed(corners[3]))
    }

    func updateFill() {
        // [glass-bubbles] Glass, or the solid fill below; a change between them redraws the outline (the tail).
        let glassy = wantsGlass
        if glassy != drawsGlass {
            drawsGlass = glassy
            GlassBubbles.track(self, glassy)
            updatePath()
        }
        if glassy {
            setTinted(false)
            applyGlass()
            return
        }
        glass?.isHidden = true
        edge?.isHidden = true
        // [tinted-bubbles] Tinted, or the solid fill below while its picture is made.
        if wantsTint {
            setTinted(true)
            if applyTint() {
                alignTint()
                return
            }
        }
        setTinted(false)
        // [desktoplook] Replies have no bubble (text straight on the page); your message is a bordered box
        // (phone-ui-desktop.css:230-266). High Contrast boxes a reply too, softly: half the card's fill over the page
        // and an edge of the text at an eighth (owner, 2026-10-26: half, a third and a fifth were still too heavy,
        // and the full fill looked like the composer's field).
        if Theme.isDesktop {
            let mine = fill == ChatPalette.meBubble
            let boxedReply = isReply && !mine && !HQShape.plainReplies
            let plainReply = fill == ChatPalette.botBubble && !boxedReply
            let shown = fill.resolvedColor(with: traitCollection)
            shapeLayer.fillColor = plainReply ? UIColor.clear.cgColor
                : boxedReply ? shown.withAlphaComponent(shown.cgColor.alpha * 0.5).cgColor : shown.cgColor
            shapeLayer.lineWidth = mine || boxedReply ? 1 : 0
            if mine {
                shapeLayer.strokeColor = ChatPalette.meBorder.resolvedColor(with: traitCollection).cgColor
            } else if boxedReply {
                let ink = ChatPalette.label.resolvedColor(with: traitCollection)
                shapeLayer.strokeColor = ink.withAlphaComponent(ink.cgColor.alpha * 0.12).cgColor
            } else {
                shapeLayer.strokeColor = nil
            }
            return
        }
        shapeLayer.fillColor = fill.resolvedColor(with: traitCollection).cgColor
        if traitCollection.accessibilityContrast == .high || HQAccessibility.overrides.contrast {
            // Increase Contrast: bubbles gain an edge (spec 06 §1.2).
            shapeLayer.lineWidth = 1
            shapeLayer.strokeColor = (fill == ChatPalette.meBubble
                ? UIColor(white: 0, alpha: 0.3) : ChatPalette.label3).resolvedColor(with: traitCollection).cgColor
        } else if let line = replyLine {
            shapeLayer.lineWidth = replyLineWidth
            shapeLayer.strokeColor = line.cgColor
        } else {
            shapeLayer.lineWidth = 0
            shapeLayer.strokeColor = nil
        }
    }
}

final class ChatBubbleCell: ChatBaseCell, UIContextMenuInteractionDelegate {
    static let reuse = "bubble"
    private let bubble = SpokenLabelView()
    private let shape = BubbleShapeView()
    private var blockViews: [BlockView] = []
    fileprivate var blockViewsOnShow: [BlockView] { blockViews.filter { !$0.isHidden } }
    private let timeLabel = UILabel()
    /// Where the layout put the time (`mediaView.timeOffset` moves it onto a stack's top card).
    private var timeFrame = CGRect.zero
    private let showMore = UIControl()
    private let showMoreLabel = UILabel()
    private var copyText = ""
    private var mine = false
    /// What the spoken label is made from (set in configure); the label itself is built when asked for.
    private var spokenMarkdown = false
    private var spokenSpeaker: String?
    private var spokenCache: (source: String, markdown: Bool, speaker: String?, label: String)?
    #if DEBUG
    /// Tests: how many spoken labels were built.
    static var spokenBuilds = 0
    #endif
    /// [attachments] Photos and file rows inside the bubble (docs/spec/1x-attachments.md §7.3).
    let mediaView = BubbleMediaView()
    private var textElement: SpokenLabelElement?
    /// VOICE: the memo's audio message (spec 1x-voice §5), made on first use.
    private var memoView: MemoBubbleView?
    /// [groups] Another sender's name and face (docs/spec/3x-groups.md §7.12), made on first use.
    private var senderLabel: UILabel?
    private var senderFace: HeadView?

    /// [groups] The name in its bot's colour at 4.5:1 on the bubble, the face in the column beside the run's last bubble.
    private func configureSender(_ b: BubbleLayout, style: ChatStyle) {
        if let name = b.senderName {
            let label = senderLabel ?? {
                let made = UILabel()
                made.lineBreakMode = .byTruncatingTail
                made.isAccessibilityElement = false
                made.accessibilityIdentifier = "chat.sender.name"
                bubble.addSubview(made)
                senderLabel = made
                return made
            }()
            label.isHidden = false
            label.font = TextLayout.senderNameFont(style)
            label.text = name
            label.textColor = ChatSenderPalette.nameColor(hex: b.senderColorHex)
            label.frame = b.senderNameFrame
        } else {
            senderLabel?.isHidden = true
        }
        if let frame = b.faceFrame, let sender = b.faceSender {
            let face = senderFace ?? {
                let made = HeadView(side: TextLayout.senderFace)
                made.isUserInteractionEnabled = false
                made.isAccessibilityElement = false
                made.accessibilityIdentifier = "chat.sender.face"
                contentView.addSubview(made)
                senderFace = made
                return made
            }()
            face.isHidden = false
            face.frame = frame
            face.configure(raw: sender.head, profile: sender.profile)
        } else {
            senderFace?.isHidden = true
        }
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        bubble.clipsToBounds = false
        contentView.addSubview(bubble)
        bubble.addSubview(shape)
        bubble.addSubview(mediaView)                                                               // [attachments]
        mediaView.delegateProvider = { [weak self] in self?.delegate as? ChatMediaCellDelegate }
        mediaView.onStackMotion = { [weak self] p in self?.timeLabel.alpha = 1 - p }   // the time over a flipping stack
        mediaView.onTimeOffset = { [weak self] o in   // and in the corner of the stack's top card
            guard let self else { return }
            self.timeLabel.frame = self.timeFrame.offsetBy(dx: o.dx, dy: o.dy)
        }
        timeLabel.adjustsFontForContentSizeCategory = false
        bubble.addSubview(timeLabel)
        showMore.addTarget(self, action: #selector(showMoreTapped), for: .touchUpInside)
        showMore.isHidden = true
        showMore.isAccessibilityElement = false   // the bubble offers it as a custom action
        showMoreLabel.isUserInteractionEnabled = false
        showMore.addSubview(showMoreLabel)
        bubble.addSubview(showMore)
        bubble.addInteraction(UIContextMenuInteraction(delegate: self))
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        bubble.addGestureRecognizer(tap)
        bubble.isAccessibilityElement = true
        #if !targetEnvironment(macCatalyst)
        // Swipe to Reply (a bot's bubble): the Mac has Reply in the hold menu instead.
        replyPan.addTarget(self, action: #selector(replyPanned(_:)))
        replyGate.cell = self
        replyPan.delegate = replyGate
        contentView.addGestureRecognizer(replyPan)
        #else
        // [mac] Drag across a message's text to select part of it; ⌘C or the menu's Copy takes it, ⌘A takes the whole
        // message (Mac audit #11, ChatTextSelection.swift).
        textSelector = ChatTextSelector(host: bubble, owner: self, surfaces: { [weak self] in self?.blockViewsOnShow ?? [] },
                                        color: { [weak self] in self?.selectionColor ?? .clear })
        textSelector?.canReceive = { [weak self] touch in self?.replyShouldReceive(touch) ?? false }
        bubble.addInteraction(UIPointerInteraction(delegate: self))
        bubble.addInteraction(UIDragInteraction(delegate: self))   // [mac] #19: a selection, or the message, drags out
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ row: ChatRow, layout: RowLayout) {
        super.configure(row, layout: layout)
        guard case .bubble(let b) = layout.content, case .bubble(let spec) = row.kind else { return }
        mine = b.mine
        copyText = b.copyText
        spokenMarkdown = spec.markdown
        spokenSpeaker = spec.speaker
        bubble.frame = b.frame
        bubble.alpha = b.dimmed ? 0.6 : 1
        shape.frame = bubble.bounds
        shape.isReply = !b.mine
        shape.fill = b.mine ? ChatPalette.meBubble : ChatPalette.botBubble
        shape.key = b.shape
        shape.isHidden = b.mediaOnly                                                               // [attachments] the photos are the bubble
        let mediaStyle = ChatStyleCache.shared.style(for: traitCollection.preferredContentSizeCategory)
        mediaView.configure(b, messageId: row.messageId, style: mediaStyle)                        // [attachments]
        // Blocks
        while blockViews.count < b.blocks.count {
            let v = BlockView()
            let index = blockViews.count
            v.onToggleCode = { [weak self] in
                guard let self else { return }
                self.delegate?.chatCellToggleCode(rowId: self.rowId, block: index)
            }
            v.onExpandTable = { [weak self] table in self?.delegate?.chatCellOpenTable(table) }   // [transcript] L309
            v.onOpenLink = { [weak self] url in self?.delegate?.chatCellOpen(url: url) }           // [transcript] link chip
            bubble.insertSubview(v, belowSubview: timeLabel)
            blockViews.append(v)
        }
        for (i, v) in blockViews.enumerated() {
            if i < b.blocks.count {
                v.isHidden = false
                v.configure(b.blocks[i], mine: b.mine)
                v.setStreaming(spec.streaming && !b.mine, key: "\(row.id):\(i)")
            } else {
                v.isHidden = true
                v.setStreaming(false, key: "")
            }
        }
        let style = ChatStyleCache.shared.style(for: traitCollection.preferredContentSizeCategory)
        if let time = b.timeText {
            timeLabel.isHidden = false          // [desktoplook] the layout leaves the time out where the look has none
            timeLabel.attributedText = NSAttributedString(string: time, attributes: [
                .font: style.time,
                // [attachments] over a photo-only bubble the time is white in its dim capsule
                .foregroundColor: b.timeCapsule != nil ? UIColor.white : (b.mine ? ChatPalette.meTime : ChatPalette.label2),
            ])
            timeFrame = b.timeFrame
            let o = b.timeCapsule != nil ? mediaView.timeOffset : .zero
            timeLabel.frame = b.timeFrame.offsetBy(dx: o.dx, dy: o.dy)
        } else {
            timeLabel.isHidden = true
        }
        if let frame = b.showMoreFrame {
            showMore.isHidden = false
            showMore.frame = frame
            // Caption 2 semibold, 10 pt in, its line 5 pt above the bubble's bottom (beside the time).
            var showMoreLook: [NSAttributedString.Key: Any] = [
                .font: style.timeBold, .foregroundColor: b.mine ? ChatPalette.meTime : ChatPalette.tintText,
            ]
            // [a11y] Button Shapes: a text-only button is underlined, as the system does for its own plain buttons.
            if HQAccessibility.buttonShapes { showMoreLook[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            showMoreLabel.attributedText = NSAttributedString(string: "Show More", attributes: showMoreLook)
            let lineH = style.timeLineHeight
            showMoreLabel.frame = CGRect(x: 10, y: frame.height - 5 - lineH, width: max(0, frame.width - 20), height: lineH)
        } else {
            showMore.isHidden = true
        }
        configureSender(b, style: style)   // [groups]
        // VoiceOver: "You said:" / "<Bot> said:" once per message (spec 03 §10), then the text.
        // [transcript] A reply is read as its words, not its Markdown (docs/spec/3x-transcript.md §9.1, L300).
        // [perf] Built only when an accessibility client asks (a dozen regex passes over the whole reply), not on
        // every configure: chat open, each scroll dequeue and each streamed frame of the live reply.
        bubble.spoken = { [weak self] in self?.spokenLabel() }
        // [a11y] A time the look leaves out (Fewer Timestamps, the Desktop Look's own messages) is still read. A message
        // from before today says its day too ("Yesterday 9:14 AM"), so a message reached by swiping is placed in time.
        bubble.accessibilityValue = spec.pending ? "Sending" : (spec.time ?? spec.spokenTime).map(Self.spokenWhen) ?? b.timeText
        // [transcript] "Message actions" opens the hold menu's items for VoiceOver (docs/spec/3x-transcript.md §9.2, L366).
        bubble.accessibilityCustomActions = (b.showMoreFrame == nil ? [] : [
            UIAccessibilityCustomAction(name: "Show More") { [weak self] _ in self?.showMoreTapped(); return true },
        ]) + (!b.mine && delegate?.chatCellCanReply(rowId: row.id) == true ? [
            UIAccessibilityCustomAction(name: "Reply") { [weak self] _ in
                guard let self else { return false }
                self.delegate?.chatCellReply(rowId: self.rowId)
                return true
            },
        ] : []) + fileActions(b) + [messageActionsAction()]
        // [attachments] one element per photo and file, then the words (spec §7.3)
        let controls = blockViews.filter { !$0.isHidden }.flatMap(\.accessibleControls)
        if mediaView.hasContent || !controls.isEmpty {
            bubble.isAccessibilityElement = false
            let media = mediaView.hasContent ? mediaView.accessibleViews : []
            // [transcript] A bubble with photos or files is a container, and a container's custom actions are never
            // offered: each element VoiceOver can land on carries "Message actions" itself.
            for view in media {
                let own = (view.accessibilityCustomActions ?? []).filter { $0.name != MessageActionsSheet.name }
                view.accessibilityCustomActions = own + [messageActionsAction()]
            }
            var elements: [Any] = media
            if !b.blocks.isEmpty {
                let element = textElement ?? SpokenLabelElement(accessibilityContainer: bubble)
                textElement = element
                element.spoken = { [weak self] in self?.spokenLabel() }
                element.accessibilityValue = bubble.accessibilityValue
                element.accessibilityCustomActions = bubble.accessibilityCustomActions
                // A page card is its own button: the words leave its block out, or a touch on the card (VoiceOver's,
                // a UI test's) finds the words first. A card alone keeps the frame but comes after the card.
                let words = zip(b.blocks, blockViews).filter { !$1.showsPageCard }.map(\.0.frame)
                element.accessibilityFrameInContainerSpace = (words.isEmpty ? b.blocks.map(\.frame) : words).reduce(CGRect.null) { $0.union($1) }
                if words.isEmpty {
                    elements += controls
                    elements.append(element)
                } else {
                    elements.append(element)
                    elements += controls
                }
            } else {
                elements += controls
            }
            bubble.accessibilityElements = elements
        } else {
            bubble.isAccessibilityElement = true
            bubble.accessibilityElements = nil
        }
        configureMemo(b, row: row, speaker: spec.speaker)   // VOICE
        #if targetEnvironment(macCatalyst)
        textSelector?.refresh()   // [mac] a selection in this row draws again on the new pieces
        #endif
    }

    /// A bubble's time for VoiceOver: the clock today, the day separator's words before that ("Yesterday 9:14 AM").
    static func spokenWhen(_ date: Date) -> String {
        Calendar.autoupdatingCurrent.isDateInToday(date) ? ChatRowBuilder.clock(date) : ChatRowBuilder.dayLabel(date, now: Date())
    }

    /// "Open day-trips.md" for each file a reply names (`FileLinks`), then "Open example.com" for each web link in its
    /// words: the taps VoiceOver can't make (the bubble is one element, so a link inside a sentence had no way in).
    private func fileActions(_ b: BubbleLayout) -> [UIAccessibilityCustomAction] {
        var seen = Set<URL>()
        var actions: [UIAccessibilityCustomAction] = []
        var web: [UIAccessibilityCustomAction] = []
        for placed in b.blocks {
            let text: NSAttributedString
            switch placed.block {
            case .text(let s), .quote(let s, _): text = s
            default: continue
            }
            text.enumerateAttribute(.chatLink, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                guard let url = value as? URL, seen.insert(url).inserted else { return }
                guard let path = FileLinks.path(fromLink: url) else {
                    guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
                    // Two links to one site are told apart by their address.
                    var site = url.host() ?? url.absoluteString
                    if web.contains(where: { $0.name == "Open \(site)" }) {
                        site = url.absoluteString.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
                    }
                    web.append(UIAccessibilityCustomAction(name: "Open \(site)") { [weak self] _ in
                        self?.delegate?.chatCellOpen(url: url)
                        return true
                    })
                    return
                }
                let name = FileLinks.place(path).name ?? (path as NSString).lastPathComponent
                actions.append(UIAccessibilityCustomAction(name: "Open \(name)") { [weak self] _ in
                    self?.delegate?.chatCellOpen(url: url)
                    return true
                })
            }
        }
        return actions + web
    }

    /// [transcript] "Message actions" opens the hold menu's items without the hold (docs/spec/3x-transcript.md §9.2,
    /// L366): VoiceOver's custom action, and Control-Return on a keyboard.
    private func messageActionsAction() -> UIAccessibilityCustomAction {
        UIAccessibilityCustomAction(name: MessageActionsSheet.name) { [weak self] _ in self?.openMessageActions() ?? false }
    }

    @discardableResult
    func openMessageActions() -> Bool {
        guard let menu = delegate?.chatCellMenu(rowId: rowId, source: bubble) else { return false }
        return MessageActionsSheet.present(menu, from: bubble)
    }

    /// The names of the custom actions on every element VoiceOver can land on in this bubble (tests and the DEBUG probe).
    var accessibilityActionNamesByElement: [[String]] {
        if bubble.isAccessibilityElement { return [(bubble.accessibilityCustomActions ?? []).map(\.name)] }
        return (bubble.accessibilityElements ?? []).map { ($0 as? NSObject)?.accessibilityCustomActions?.map(\.name) ?? [] }
    }

    /// The bubble's VoiceOver label, "<speaker> said: <words>", made from the current content (memoized on it).
    func spokenLabel() -> String {
        if let c = spokenCache, c.source == copyText, c.markdown == spokenMarkdown, c.speaker == spokenSpeaker { return c.label }
        #if DEBUG
        Self.spokenBuilds += 1
        #endif
        // [attachments] a reply's picture is read by its name, not its path (docs/spec/1x-attachments.md §7.5)
        let spoken = spokenMarkdown ? (mine ? UserMarkdown.spoken(copyText) : SpokenMarkdown.plain(MediaTags.forSpeech(copyText))) : copyText
        let label = spokenSpeaker.map { "\($0) said: " + spoken } ?? spoken
        spokenCache = (copyText, spokenMarkdown, spokenSpeaker, label)
        return label
    }

    /// VOICE: a memo bubble draws its audio message; its parts are separate VoiceOver elements.
    private func configureMemo(_ b: BubbleLayout, row: ChatRow, speaker: String?) {
        guard let geometry = b.memo else {
            // (VoiceOver elements for a non-memo bubble were set above, with its photos and files.)
            memoView?.isHidden = true
            memoView?.reset()
            return
        }
        let view = memoView ?? {
            let made = MemoBubbleView()
            bubble.insertSubview(made, belowSubview: timeLabel)
            memoView = made
            return made
        }()
        view.isHidden = false
        view.frame = bubble.bounds
        view.onToggleMore = { [weak self] in
            guard let self else { return }
            self.delegate?.chatCellToggle(rowId: self.rowId)
        }
        view.configure(geometry, scope: row.scope, speaker: speaker)
        bubble.isAccessibilityElement = false
        bubble.accessibilityElements = [view]
        // [transcript] The memo's own elements carry "Message actions" too (the bubble is their container).
        for element in (view.accessibilityElements as? [NSObject]) ?? [view] {
            let own = (element.accessibilityCustomActions ?? []).filter { $0.name != MessageActionsSheet.name }
            element.accessibilityCustomActions = own + [messageActionsAction()]
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        settleReply(animated: false)
        mediaView.prepareForReuse()                                                                // [attachments]
        timeLabel.alpha = 1
        #if targetEnvironment(macCatalyst)
        endSelection()
        #endif
    }

    /// [attachments] The link came back: failed photos in this bubble try again (spec 1x §7.4).
    func retryFailedMedia() { mediaView.retryFailedAfterReconnect() }

    override func updateWindowRect(in table: UITableView) {
        for v in blockViews where !v.isHidden {
            v.setWindowRect(table.convert(table.bounds, to: v))
        }
    }

    // MARK: Send lift (spec 06 §5.2)

    /// Where a bubble's text is drawn inside the row (its first block's visible text area), top-down row coordinates.
    static func textBox(_ b: BubbleLayout) -> CGRect? {
        guard let block = b.blocks.first else { return nil }
        return CGRect(x: b.frame.minX + block.frame.minX + block.textFrame.minX, y: b.frame.minY + block.frame.minY + block.textFrame.minY,
                      width: block.textFrame.width, height: block.textFrame.height)
    }

    /// The lift's stand-in: this row drawn upright, outside the table, in `host` above `sibling` (the composer). Added
    /// before it is configured, so its colours and fonts resolve with the screen's traits.
    static func liftStandIn(_ row: ChatRow, layout: RowLayout, width: CGFloat, host: UIView, above sibling: UIView) -> ChatBubbleCell {
        let cell = ChatBubbleCell(style: .default, reuseIdentifier: nil)
        cell.shape.allowsGlass = false   // [glass-bubbles] the reveal mask would cut glass flat
        cell.contentView.transform = .identity
        cell.frame = CGRect(x: 0, y: 0, width: width, height: layout.height)
        host.insertSubview(cell, aboveSubview: sibling)
        cell.layoutIfNeeded()
        cell.contentView.frame = cell.bounds
        cell.configure(row, layout: layout)
        cell.isUserInteractionEnabled = false
        cell.isAccessibilityElement = false
        cell.accessibilityElementsHidden = true
        return cell
    }

    private var revealMask: CAShapeLayer?

    /// Clips the bubble to its box inset by `insets` (negative = beyond it), round 18; nil shows it whole. The bubble
    /// opens out from a tight shape around its text to its own (its tail and time included).
    func setReveal(_ insets: UIEdgeInsets?) {
        guard let insets else {
            bubble.layer.mask = nil
            revealMask = nil
            return
        }
        let mask = revealMask ?? CAShapeLayer()
        revealMask = mask
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let rect = bubble.bounds.inset(by: insets)
        mask.frame = bubble.bounds
        mask.path = UIBezierPath(roundedRect: rect, cornerRadius: min(ChatMetrics.bubbleRadius, rect.height / 2, rect.width / 2)).cgPath
        if bubble.layer.mask !== mask { bubble.layer.mask = mask }
        CATransaction.commit()
    }

    /// The bubble's box inside the row.
    var bubbleFrame: CGRect { bubble.frame }

    // MARK: Find in chat

    /// Marks the find query's occurrences in the bubble's text (nil clears them); `current` counts across its blocks.
    func setFind(_ highlight: ChatFindHighlight?) {
        var seen = 0
        for v in blockViews where !v.isHidden {
            let local = highlight?.current.map { $0 - seen }
            seen += v.setFind(highlight?.query, current: local.flatMap { $0 >= 0 ? $0 : nil })
        }
        for v in blockViews where v.isHidden { v.setFind(nil, current: nil) }
    }

    /// The current match's box in the row (top-down, the row's own coordinates), if this bubble holds it.
    func currentFindRect() -> CGRect? {
        for v in blockViews where !v.isHidden {
            if let rect = v.currentFindRect() { return v.convert(rect, to: contentView) }
        }
        return nil
    }

    @objc private func showMoreTapped() {
        Haptics.play(.selection)
        delegate?.chatCellToggle(rowId: rowId)
    }

    @objc private func tapped(_ gr: UITapGestureRecognizer) {
        #if targetEnvironment(macCatalyst)
        // A click puts a selection away (a click on this message's text makes it the one ⌘A selects).
        if let active = ChatTextSelector.active, active.hasSelection { active.clear(); return }
        #endif
        for v in blockViews where !v.isHidden {
            let p = gr.location(in: v)
            if v.bounds.contains(p), let url = v.link(at: p) {
                delegate?.chatCellOpen(url: url)
                return
            }
        }
        // Inline code and code cards copy with one tap (Telegram's monospace spans); a link above wins.
        for v in blockViews where !v.isHidden {
            let p = gr.location(in: v)
            if v.bounds.contains(p), let text = v.copyable(at: p) {
                ChatTapCopy.copy(text, from: v)
                return
            }
        }
        // [transcript] A tap on a table opens it on the Table page.
        for v in blockViews where !v.isHidden {
            if v.expandTableIfHit(gr.location(in: v)) { return }
        }
        #if targetEnvironment(macCatalyst)
        if onText(gr.location(in: bubble)) { textSelector?.focus() }   // [mac] #11: ⌘A now selects this message
        #endif
    }

    // MARK: [mac] Selecting text with the mouse

    #if targetEnvironment(macCatalyst)
    /// Mac audit 2026-11-02 #11: the drag, the spots and Copy (ChatTextSelection.swift).
    private var textSelector: ChatTextSelector?

    /// What is selected, as plain words; nil with nothing selected.
    var selectedText: String? { textSelector?.selectedText }

    /// The highlight: the theme's tint under a reply's words (as iOS's own selection), white under yours (your bubble
    /// is often the tint itself).
    private var selectionColor: UIColor { Self.selectionColor(mine: mine, desktopLook: ThemeTable.desktopLook) }

    /// In the Desktop Look your box is the skin's pale user colour, never the tint, so your words take the reply's
    /// highlight too: the white read as a grey, stuck selection there (Mac polish #74).
    static func selectionColor(mine: Bool, desktopLook: Bool) -> UIColor {
        mine && !desktopLook ? UIColor.white.withAlphaComponent(0.35) : DesktopFrost.tint(ChatPalette.tint)
    }

    /// The point (bubble coordinates) is on the message's words.
    private func onText(_ point: CGPoint) -> Bool {
        visiblePieces().contains { $0.convert($0.bounds, to: bubble).contains(point) }
    }

    /// [mac] Stress test 2026-10-28 #19: the point (bubble coordinates) is on the selected words.
    private func inSelection(_ point: CGPoint) -> Bool { textSelector?.isOnSelection(point) ?? false }

    /// [mac] Stress test 2026-10-28 #19: what a drag out of the bubble carries, as in Messages and Mail: the selected
    /// words from a press on them, the whole message from a press off its text (the bubble's edge, its time). A press
    /// on unselected text selects instead (`ChatTextSelector`); photos and files drag on their own (`BubbleMediaView`).
    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        let point = session.location(in: bubble)
        let text: String?
        if inSelection(point) {
            text = selectedText
        } else if onText(point) {
            text = nil
        } else {
            text = copyText.isEmpty ? nil : copyText
        }
        guard let text else { return [] }
        AppLog.trace("chatui", "message drag started (\(text.count) chars)")
        return [UIDragItem(itemProvider: NSItemProvider(object: text as NSString))]
    }

    private func visiblePieces() -> [TextDrawView] { blockViews.filter { !$0.isHidden }.flatMap(\.drawnPieces) }

    func endSelection() { textSelector?.clear() }

    #if DEBUG
    var debugIsReply: Bool { !mine && !visiblePieces().isEmpty }
    var debugSelector: ChatTextSelector? { textSelector }
    var debugBubble: UIView { bubble }
    var debugBlocks: [BlockView] { blockViewsOnShow }

    /// The Mac tour: selects from near the start of the text to partway through its last piece, as a drag would.
    func debugSelect() {
        let pieces = visiblePieces()
        guard let first = pieces.first, let last = pieces.last, let textSelector else { return }
        let from = first.convert(CGPoint(x: 2, y: 4), to: bubble)
        let to = last.convert(CGPoint(x: last.bounds.width * 0.6, y: last.bounds.height - 4), to: bubble)
        guard textSelector.begin(at: from) else { return }
        textSelector.move(to: to)
        if textSelector.hasSelection { becomeFirstResponder() }
    }
    #endif

    /// The cell holds the keyboard while its message has a selection or was the last clicked (for ⌘A).
    override var canBecomeFirstResponder: Bool { textSelector?.isActive ?? false }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) { return selectedText != nil }
        if action == #selector(selectAll(_:)) { return textSelector?.isActive ?? false }
        return super.canPerformAction(action, withSender: sender)
    }

    override func copy(_ sender: Any?) { textSelector?.copySelection() }

    override func selectAll(_ sender: Any?) { textSelector?.selectAll() }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { textSelector?.clear(resign: false) }   // the keyboard went elsewhere (the composer, a list)
        return resigned
    }
    #endif

    // MARK: Swipe to Reply

    private let replyPan = UIPanGestureRecognizer()
    /// The pan's own delegate: the cell is already its table's gesture delegate, and UIKit's super doesn't answer these.
    private let replyGate = ReplySwipeGate()
    /// The arrow at the screen's trailing edge that the row uncovers as it slides left, made on first use. It sits in
    /// the cell (which stays put), not the sliding contentView, so it is always on screen.
    private var replyIcon: UIView?
    /// Past the threshold: letting go begins the reply (the haptic marks each crossing).
    private var replyArmed = false
    private static let replyThreshold: CGFloat = 72
    private static let replyIconSide: CGFloat = 34

    /// The row slid `dx` (≤ 0) to the left, finger for finger. It shifts the contentView's bounds, not its transform:
    /// the cell re-lays out its contentView's frame on every pass, which wipes out a translation in the transform.
    private func setReplyOffset(_ dx: CGFloat) {
        slideLeft = -dx
        guard let icon = replyIcon else { return }
        // Grows and slides in from the edge as the pull nears the threshold, then pops and fills once armed.
        let progress = min(1, -dx / Self.replyThreshold)
        let scale = replyArmed ? 1.12 : 0.5 + 0.5 * progress
        icon.alpha = progress
        icon.transform = CGAffineTransform(scaleX: scale, y: -scale).translatedBy(x: (1 - progress) * 24, y: 0)
    }

    private func setReplyArmedLook(_ armed: Bool) {
        (replyIcon as? ReplyArrowView)?.armed = armed
    }

    private func settleReply(animated: Bool) {
        replyArmed = false
        guard slideLeft != 0 || replyIcon?.alpha ?? 0 > 0 else { return }
        let back = { self.setReplyOffset(0) }
        if animated && !HQMotion.reduced {
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState], animations: back) { _ in
                self.setReplyArmedLook(false)
            }
        } else {
            back()
            setReplyArmedLook(false)
        }
    }

    /// The arrow at the trailing edge, level with the finger (made on first use), at rest before the pull.
    private func placeReplyIcon(fingerY: CGFloat) {
        let side = Self.replyIconSide
        let icon = replyIcon ?? {
            let made = ReplyArrowView(side: side)
            made.isAccessibilityElement = false
            made.accessibilityIdentifier = "chat.swipe-reply"
            // Under the sliding row, so the row uncovers it.
            insertSubview(made, belowSubview: contentView)
            replyIcon = made
            return made
        }()
        setReplyArmedLook(false)
        // At the trailing edge, level with the finger but kept on the bubble (a tall reply may be mostly off
        // screen). The cell is flipped with its table, so the icon is flipped back (in setReplyOffset).
        icon.transform = .identity
        let frame = bubble.convert(bubble.bounds, to: self)
        let y = min(max(fingerY, frame.minY + side / 2), frame.maxY - side / 2)
        let x = bounds.maxX - max(safeAreaInsets.right, 0) - 20 - side
        icon.frame = CGRect(x: x, y: y - side / 2, width: side, height: side)
        replyArmed = false
        setReplyOffset(0)
    }

    #if DEBUG
    /// [glass-phone] Screenshots: the row held `pull` points to the left as a finger would hold it (armed past 72 pt).
    func debugHoldReplySwipe(pull: CGFloat) {
        placeReplyIcon(fingerY: bubble.convert(CGPoint(x: 0, y: bubble.bounds.midY), to: self).y)
        replyArmed = pull >= Self.replyThreshold
        setReplyArmedLook(replyArmed)
        setReplyOffset(-pull)
    }
    var debugIsMine: Bool { mine }
    #endif

    @objc private func replyPanned(_ gr: UIPanGestureRecognizer) {
        switch gr.state {
        case .began:
            placeReplyIcon(fingerY: gr.location(in: self).y)
        case .changed:
            // The whole row follows the thumb, all the way off the screen if it's pulled that far.
            let pull = min(max(0, -gr.translation(in: self).x), bounds.width)
            let armed = pull >= Self.replyThreshold
            if armed != replyArmed {
                replyArmed = armed
                setReplyArmedLook(armed)
                if armed { Haptics.play(.medium) }
                if !HQMotion.reduced {
                    UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0,
                                   options: [.allowUserInteraction, .beginFromCurrentState]) { self.setReplyOffset(-pull) }
                    break
                }
            }
            setReplyOffset(-pull)
        case .ended:
            let reply = replyArmed
            settleReply(animated: true)
            if reply { delegate?.chatCellReply(rowId: rowId) }
        default:
            settleReply(animated: true)
        }
    }

    /// Leftward and mostly sideways on a bot's bubble: the table keeps every vertical drag.
    fileprivate func replyShouldBegin() -> Bool {
        guard !mine, delegate?.chatCellCanReply(rowId: rowId) == true else { return false }
        let v = replyPan.velocity(in: self)
        return v.x < 0 && abs(v.x) > abs(v.y) * 1.5
    }

    /// A code block or table that scrolls sideways keeps its own drag, and so does a photo stack (it flips).
    fileprivate func replyShouldReceive(_ touch: UITouch) -> Bool {
        var view = touch.view
        while let v = view, v !== contentView {
            if let scroll = v as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1 { return false }
            if v is PhotoStackView { return false }
            view = v.superview
        }
        return true
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        // [transcript] A link or a link chip under the finger gets the link's own menu; anywhere else, the message's.
        for v in blockViews where !v.isHidden {
            let p = bubble.convert(location, to: v)
            if v.bounds.contains(p), let url = v.heldLink(at: p), let menu = delegate?.chatCellLinkMenu(url: url, source: bubble) {
                return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
            }
        }
        #if targetEnvironment(macCatalyst)
        // [mac] With part of the message selected, Copy Selection takes that part, ahead of the message's own menu.
        if let selected = selectedText {
            let copy = UIAction(title: "Copy Selection", image: UIImage(systemName: "text.cursor")) { _ in UIPasteboard.general.string = selected }
            copy.accessibilityIdentifier = "selection.copy"
            let rest = delegate?.chatCellMenu(rowId: rowId, source: bubble)
            rest.map(ChatTextSelector.nameWholeCopy)   // its own Copy reads "Copy Message" beside it (Mac audit #11)
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                UIMenu(children: [copy] + (rest.map { [UIMenu(options: .displayInline, children: $0.children)] } ?? []))
            }
        }
        #endif
        let text = copyText
        // MENUS (spec 1x §9): the whole message's menu (Copy, Share, Select Text, Show/Hide Steps) when the screen
        // offers one; otherwise Copy plus [activity] Show / Hide Steps on a reply (docs/spec/1x-activity.md §10.5).
        let menu = delegate?.chatCellMenu(rowId: rowId, source: bubble)
        var extra = mine || menu != nil ? [] : ((delegate as? ChatCellMenuExtending)?.chatCellMenuItems(rowId: rowId) ?? [])
        // [mac] Stress test 2026-10-28 #16: Swipe to Reply's menu twin in this short menu too (the Mac has no swipe).
        if !mine, menu == nil, delegate?.chatCellCanReply(rowId: rowId) == true {
            let id = rowId
            let reply = UIAction(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left")) { [weak self] _ in
                self?.delegate?.chatCellReply(rowId: id)
            }
            reply.accessibilityIdentifier = "message.reply"
            extra.insert(reply, at: 0)
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            menu ?? UIMenu(children: [UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = text
                Haptics.play(.success)
            }] + extra)
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        preview()
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        preview()
    }

    private func preview() -> UITargetedPreview {
        let params = UIPreviewParameters()
        params.backgroundColor = .clear
        if let path = shape.shapeLayer.path { params.visiblePath = UIBezierPath(cgPath: path) }
        return UITargetedPreview(view: bubble, parameters: params)
    }
}

/// [glass-phone] Swipe to Reply's arrow: a small native glass circle like the house's other glass circles (the jump
/// button), untinted while pulling and the accent's tinted glass once armed (owner 2026-10-30: more Liquid Glass). The
/// cell fades and scales this holder, never the glass itself. The Desktop Look has no glass: there it is today's flat
/// circle (Fill 3, the accent once armed), drawn here, so ThemeChrome leaves the glass alone.
final class ReplyArrowView: UIView {
    private let glass = UIVisualEffectView()
    private let arrow = UIImageView(image: UIImage(systemName: "arrowshape.turn.up.left.fill",
                                                   withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium)))
    var armed = false { didSet { if armed != oldValue { applyLook() } } }

    init(side: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
        isUserInteractionEnabled = false
        DesktopLayout.keepOwnLook(glass)
        glass.cornerConfiguration = .capsule()
        addSubview(glass)
        arrow.contentMode = .center
        addSubview(arrow)
        layer.cornerRadius = side / 2
        applyLook()
        registerForTraitChanges([ThemeGenerationTrait.self]) { (view: ReplyArrowView, _) in view.applyLook() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        arrow.frame = bounds
        layer.cornerRadius = bounds.width / 2
    }

    /// Whether the circle is glass now, and tinted (tests).
    var isGlass: Bool { glass.effect is UIGlassEffect }
    var glassTint: UIColor? { (glass.effect as? UIGlassEffect)?.tintColor }

    private func applyLook() {
        if Theme.isDesktop {
            if glass.effect != nil { glass.effect = nil }
            glass.isHidden = true
            backgroundColor = armed ? ChatPalette.tint : ChatPalette.fill3
        } else {
            // Not interactive: the arrow is never touched, the finger is on the row.
            let effect = UIGlassEffect(style: .regular)
            if armed { effect.tintColor = ChatPalette.tint }
            glass.isHidden = false
            glass.effect = effect
            backgroundColor = nil
        }
        arrow.tintColor = armed ? ChatPalette.onTint : ChatPalette.label2
    }
}

/// Swipe to Reply's gesture delegate, kept apart from the cell.
private final class ReplySwipeGate: NSObject, UIGestureRecognizerDelegate {
    weak var cell: ChatBubbleCell?

    func gestureRecognizerShouldBegin(_ gr: UIGestureRecognizer) -> Bool { cell?.replyShouldBegin() ?? false }

    func gestureRecognizer(_ gr: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        cell?.replyShouldReceive(touch) ?? false
    }
}

#if targetEnvironment(macCatalyst)
/// [mac] Stress test 2026-10-28 #19: `dragInteraction(_:itemsForBeginning:)` is with the selection code.
extension ChatBubbleCell: UIDragInteractionDelegate {}

/// [mac] An I-beam over a message's text says it can be selected.
extension ChatBubbleCell: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        guard let view = interaction.view else { return nil }
        for block in blockViewsOnShow {
            for piece in block.drawnPieces {
                let frame = piece.convert(piece.bounds, to: view)
                if frame.contains(request.location) { return UIPointerRegion(rect: frame, identifier: "text") }
            }
        }
        return nil
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(shape: .verticalBeam(length: HQFont.preferred(.body).lineHeight), constrainedAxes: [])
    }
}
#endif

// MARK: - Tool run / thought row

final class ChatToolCell: ChatBaseCell, UIContextMenuInteractionDelegate {
    static let reuse = "tool"
    private let rowButton = UIControl()
    private let glyph = CAShapeLayer()
    /// A running tool's glyph: the desktop's `breathe` spinner in tertiary text (V:tool/fallback.tsx `statusGlyph`).
    private let spinner = GlyphSpinner(style: .breathe, color: ChatPalette.label3, size: HQFont.symbolSize(13, like: .footnote, cap: 22))
    private let chevron = CAShapeLayer()
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()
    private let card = UIView()
    private var stepViews: [(UIControl, UILabel, UILabel, UIView, GlyphSpinner)] = []
    /// A long opened One Line card: "Show All N Steps" above its last steps, "Show Less" under them.
    private let showAllRow = UIControl(), showAllLabel = UILabel()
    private let showLessRow = UIControl(), showLessLabel = UILabel(), showLessRule = UIView()
    private var firstStep = 0
    private let thoughtText = TextDrawView()
    /// [botdm] The other bot's face on a bot-to-bot message row, in place of the glyph.
    private var face: HeadView?
    private var showsFace = false
    /// [updates] An update group's line: its marks (other bots' faces, glyphs) before its centred words.
    private var marks: [(view: UIView, shape: CAShapeLayer, head: HeadView?)] = []
    private var isGroup = false
    /// [updates] A soft caret after a group line's words when it opens: down while shut, up while open.
    private let caret = CAShapeLayer()
    private weak var linkTap: UITapGestureRecognizer?
    /// Reduce Motion stills the spinner and the shimmer: a still accent dot by the chevron marks a live row instead.
    private let liveDot = UIView()
    private var currentGlyph: ChatGlyph?
    private var currentGlyphSize: CGFloat = 0
    private var live = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        contentView.addSubview(rowButton)
        rowButton.layer.addSublayer(glyph)
        rowButton.layer.addSublayer(chevron)
        caret.fillColor = nil
        caret.lineWidth = 1.3
        caret.lineCap = .round
        caret.lineJoin = .round
        caret.isHidden = true
        rowButton.layer.addSublayer(caret)
        spinner.isHidden = true
        rowButton.addSubview(spinner)
        rowButton.layer.cornerRadius = 10
        rowButton.layer.cornerCurve = .continuous
        glyph.fillColor = nil
        glyph.lineWidth = 1.6
        glyph.lineCap = .round
        glyph.lineJoin = .round
        chevron.fillColor = nil
        chevron.lineWidth = 1.6
        chevron.lineCap = .round
        chevron.lineJoin = .round
        titleLabel.textColor = ChatPalette.label2
        titleLabel.lineBreakMode = .byTruncatingTail
        rowButton.addSubview(titleLabel)
        metaLabel.textAlignment = .right
        rowButton.addSubview(metaLabel)
        rowButton.addTarget(self, action: #selector(toggle), for: .touchUpInside)
        rowButton.addTarget(self, action: #selector(pressDown), for: [.touchDown, .touchDragEnter])
        rowButton.addTarget(self, action: #selector(pressUp), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        rowButton.isAccessibilityElement = true
        rowButton.accessibilityTraits = .button
        // Held: Copy, Read Aloud and Share on a delivery or a finished result; Copy Command / Copy Output on a step. The
        // row stays folded.
        rowButton.addInteraction(UIContextMenuInteraction(delegate: self))
        #if targetEnvironment(macCatalyst)
        rowButton.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        #endif
        card.backgroundColor = ChatPalette.fill4
        card.layer.cornerRadius = ChatMetrics.insetCardRadius
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        contentView.addSubview(card)
        card.addSubview(thoughtText)
        // The opened words (a thought, a report, a /btw answer) are read like a bubble's; its links are the row's actions.
        thoughtText.isAccessibilityElement = true
        thoughtText.accessibilityTraits = .staticText
        thoughtText.accessibilityIdentifier = "chat.tool.opened"
        // An opened result's links (a report's or another bot's message) open like a bubble's.
        let links = UITapGestureRecognizer(target: self, action: #selector(linkTapped(_:)))
        links.cancelsTouchesInView = false
        // On the cell, as ChatLineCell's: UIKit asks the recognizer's own view, so gestureRecognizerShouldBegin below runs.
        addGestureRecognizer(links)
        linkTap = links
        liveDot.backgroundColor = ChatPalette.tint
        liveDot.layer.cornerRadius = 3.5
        liveDot.isHidden = true
        liveDot.isUserInteractionEnabled = false
        rowButton.addSubview(liveDot)
        for (row, label, id) in [(showAllRow, showAllLabel, "chat.steps.show-all"), (showLessRow, showLessLabel, "chat.steps.show-less")] {
            label.textColor = ChatPalette.tintText
            label.lineBreakMode = .byTruncatingTail
            label.isUserInteractionEnabled = false
            row.addSubview(label)
            row.isAccessibilityElement = true
            row.accessibilityTraits = .button
            row.accessibilityIdentifier = id
            row.isHidden = true
            card.addSubview(row)
        }
        showLessRule.backgroundColor = ChatPalette.separator
        showLessRow.addSubview(showLessRule)
        showAllRow.addTarget(self, action: #selector(showAllSteps), for: .touchUpInside)
        showLessRow.addTarget(self, action: #selector(toggle), for: .touchUpInside)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self, UITraitAccessibilityContrast.self]) { (cell: ChatToolCell, _) in cell.updateColors() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// [backdrop] On its pill over a chat background the row's words and glyph take the primary label and the chevron
    /// label 2 (label 2 / label 3 measured 2.9:1 and less on the dark glass pills; owner, 2026-11-01).
    private var onPill: Bool { Backdrop.chats.shows }

    private func updateColors() {
        glyph.strokeColor = (onPill ? ChatPalette.label : ChatPalette.label2).resolvedColor(with: traitCollection).cgColor
        for mark in marks { mark.shape.strokeColor = glyph.strokeColor }
        chevron.strokeColor = (onPill ? ChatPalette.label2 : ChatPalette.label3).resolvedColor(with: traitCollection).cgColor
        caret.strokeColor = chevron.strokeColor
    }

    override func configure(_ row: ChatRow, layout: RowLayout) {
        super.configure(row, layout: layout)
        guard case .tool(let t) = layout.content else { return }
        let style = ChatStyleCache.shared.style(for: traitCollection.preferredContentSizeCategory)
        rowButton.frame = t.rowFrame
        let h = t.rowFrame.height
        let g = style.toolGlyph
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.frame = CGRect(x: ChatMetrics.toolRowPadH, y: ((h - g) / 2).rounded(), width: g, height: g)
        // [botdm] Another bot's message: its face where the glyph goes, a little larger than the glyph.
        showsFace = t.face != nil
        if let sender = t.face {
            let side = (g + 4).rounded()
            let view = face ?? {
                let made = HeadView(side: side)
                made.isUserInteractionEnabled = false
                rowButton.addSubview(made)
                face = made
                return made
            }()
            view.isHidden = false
            view.frame = CGRect(x: glyph.frame.midX - side / 2, y: glyph.frame.midY - side / 2, width: side, height: side)
            view.configure(raw: sender.head, profile: sender.profile)
        } else {
            face?.isHidden = true
        }
        if currentGlyph != t.glyph || currentGlyphSize != g {
            glyph.path = t.glyph.path(size: g)
            currentGlyph = t.glyph
            currentGlyphSize = g
        }
        let c = style.toolChevron
        chevron.frame = CGRect(x: t.rowFrame.width - ChatMetrics.toolRowPadH - c, y: ((h - c) / 2).rounded(), width: c, height: c)
        // 5 × 10 in the 16-unit box (was lucide's 4 × 8: half a list's disclosure arrow, lost beside the row's words).
        chevron.path = SVGPath.parse(t.expanded ? "M3 5.5l5 5 5-5" : "M5.5 3l5 5-5 5").copy(using: [CGAffineTransform(scaleX: c / 16, y: c / 16)])
        updateColors()
        CATransaction.commit()
        titleLabel.font = style.tool
        titleLabel.textColor = onPill ? ChatPalette.label : ChatPalette.label2
        titleLabel.text = t.title
        metaLabel.font = style.toolMeta
        metaLabel.text = t.meta
        metaLabel.textColor = t.metaIsError ? ChatPalette.red : onPill ? ChatPalette.label : ChatPalette.label2
        let metaW = t.meta.map { ceil(($0 as NSString).size(withAttributes: [.font: style.toolMeta]).width) } ?? 0
        let titleX = ChatMetrics.toolRowPadH + g + ChatMetrics.toolGap
        let metaX = chevron.frame.minX - 8 - metaW
        metaLabel.frame = CGRect(x: metaX, y: 0, width: metaW, height: h)
        titleLabel.frame = CGRect(x: titleX, y: 0, width: max(0, (t.meta == nil ? chevron.frame.minX - 8 : metaX - 8) - titleX), height: h)
        spinner.frame = glyph.frame.insetBy(dx: -2, dy: -2)
        rowButton.accessibilityLabel = t.title + (t.meta.map { ", " + $0 } ?? "")
        // A run of one opens its step sheet; longer runs open in place.
        rowButton.accessibilityValue = t.single ? nil : (t.expanded ? "Expanded" : "Collapsed")
        rowButton.accessibilityHint = t.single ? "Shows the step’s details" : nil
        isGroup = t.group != nil
        chevron.isHidden = isGroup
        rowButton.isEnabled = true
        rowButton.accessibilityTraits = .button
        if let group = t.group { layoutGroup(group, t: t, style: style) } else {
            for mark in marks { mark.view.isHidden = true }
            caret.isHidden = true
        }
        // [backdrop] A capsule as tall as the words (as a day's or a notice's), centred in the row's 40 pt press area. A
        // press shades it (`pressDown`), not the taller row.
        let pillH = min(h, ceil(max(style.tool.lineHeight, g)) + 8)
        placeBacking(rowButton.frame.insetBy(dx: 0, dy: ((h - pillH) / 2).rounded()), radius: pillH / 2)
        setLive(t.live)

        card.isHidden = !t.expanded
        if t.expanded {
            card.frame = t.cardFrame
            card.backgroundColor = Self.contentCardFill
            if let tk = t.thoughtText {
                thoughtText.isHidden = false
                thoughtText.frame = t.thoughtFrame
                thoughtText.set(layout: tk)
                thoughtText.accessibilityLabel = tk.text.string
            } else {
                thoughtText.isHidden = true
            }
            configureSteps(t, style: style)
        }
        rowButton.accessibilityCustomActions = t.expanded ? t.thoughtText.flatMap { linkActions($0.text) } : nil
    }

    /// [updates] The group's line: marks and words centred together in the row, the press area hugging them.
    /// [updates] What a group line shows in a row `width` wide: its marks (up to 3) and its words with the count.
    struct GroupLineFit {
        var shown: [UpdatesGroup.Mark]
        var text: NSAttributedString
        var side: CGFloat, spacing: CGFloat, pad: CGFloat
        var lead: CGFloat, room: CGFloat
        var caretW: CGFloat, caretGap: CGFloat, trail: CGFloat
    }

    static func fitGroup(_ group: UpdatesGroup, title: String, width: CGFloat, style: ChatStyle) -> GroupLineFit {
        let font = style.notice
        // [backdrop] On the pill over a chat background: the words in the primary label, the count in label 2.
        let ink = Backdrop.chats.shows ? ChatPalette.label : ChatPalette.label2
        let countInk = Backdrop.chats.shows ? ChatPalette.label2 : ChatPalette.label3
        let text = NSMutableAttributedString(string: title, attributes: [.font: font, .foregroundColor: ink])
        if let tail = group.tail {
            text.append(NSAttributedString(string: " · " + tail, attributes: [.font: font, .foregroundColor: countInk]))
        }
        let side = (style.toolGlyph - 2).rounded()
        var shown = Array(group.marks.prefix(3))
        let pad: CGFloat = 10, spacing: CGFloat = 4
        func leadWidth(_ n: Int) -> CGFloat { n == 0 ? 0 : CGFloat(n) * side + CGFloat(n - 1) * spacing + 6 }
        // [updates] The caret: about the footnote's cap height wide, half that high, 4 pt after the words (owner,
        // 2026-10-28: it should look like it opens, softly; a line that opens nothing has none).
        let caretW = group.opens ? max(7, font.capHeight.rounded()) : 0
        // A gap that grows with the type, so at large sizes the caret never touches the last letter (review 2026-10-28).
        let caretGap = max(5, (caretW * 0.5).rounded())
        let trail = group.opens ? caretGap + caretW : 0
        func room(_ n: Int) -> CGFloat { max(0, width - 2 * pad - leadWidth(n) - trail) }
        // [updates] Short of room (large text) the line keeps its count: first it shows one mark (the lead's) instead of
        // three, then " · 3 more" or " · 4 messages" becomes " · +3", and only then the count goes, before the words are
        // cut (review 2026-10-28: at XL "From Hermes" alone read as one message; "From Hermes · 1 m…").
        if group.tail != nil, shown.count > 1, ceil(text.size().width) > room(shown.count) { shown = Array(shown.prefix(1)) }
        let fits = room(shown.count)
        if group.tail != nil, ceil(text.size().width) > fits {
            let words = (title as NSString).length
            text.deleteCharacters(in: NSRange(location: words, length: text.length - words))
            let short = NSAttributedString(string: " · +\(group.count - 1)", attributes: [.font: font, .foregroundColor: countInk])
            let tried = NSMutableAttributedString(attributedString: text)
            tried.append(short)
            if ceil(tried.size().width) <= fits { text.append(short) }
        }
        return GroupLineFit(shown: shown, text: text, side: side, spacing: spacing, pad: pad, lead: leadWidth(shown.count),
                            room: fits, caretW: caretW, caretGap: caretGap, trail: trail)
    }

    /// [updates] The group's line: marks and words centred together in the row, the press area hugging them.
    private func layoutGroup(_ group: UpdatesGroup, t: ToolRowLayout, style: ChatStyle) {
        let font = style.notice
        let fit = Self.fitGroup(group, title: t.title, width: t.rowFrame.width, style: style)
        let text = fit.text, shown = fit.shown, side = fit.side, spacing = fit.spacing, pad = fit.pad
        let lead = fit.lead, room = fit.room, caretW = fit.caretW, caretGap = fit.caretGap, trail = fit.trail
        titleLabel.attributedText = text
        while marks.count < shown.count {
            let view = UIView()
            view.isUserInteractionEnabled = false
            let shape = CAShapeLayer()
            shape.fillColor = nil
            shape.lineWidth = 1.5
            shape.lineCap = .round
            shape.lineJoin = .round
            view.layer.addSublayer(shape)
            rowButton.addSubview(view)
            marks.append((view, shape, nil))
        }
        let textW = min(ceil(text.size().width), room)
        let contentW = lead + textW + trail
        let h = t.rowFrame.height
        rowButton.frame = CGRect(x: t.rowFrame.minX + ((t.rowFrame.width - contentW) / 2).rounded() - pad, y: t.rowFrame.minY,
                                 width: contentW + 2 * pad, height: h)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var x = pad
        for i in marks.indices {
            let view = marks[i].view
            guard i < shown.count else { view.isHidden = true; continue }
            view.isHidden = false
            view.frame = CGRect(x: x, y: ((h - side) / 2).rounded(), width: side, height: side)
            switch shown[i] {
            case .glyph(let g):
                marks[i].shape.isHidden = false
                marks[i].shape.frame = view.bounds
                marks[i].shape.path = g.path(size: side)
                marks[i].head?.isHidden = true
            case .face(let sender):
                marks[i].shape.isHidden = true
                let head = marks[i].head ?? {
                    let made = HeadView(side: side, mark: true)
                    made.isUserInteractionEnabled = false
                    view.addSubview(made)
                    marks[i].head = made
                    return made
                }()
                head.isHidden = false
                head.frame = view.bounds
                head.configure(raw: sender.head, profile: sender.profile)
            }
            x += side + spacing
        }
        caret.isHidden = !group.opens
        if group.opens {
            let caretH = (caretW * 0.5).rounded()
            // Centred on the words' capitals: the label centres its line box in the row.
            let capMid = (h - font.lineHeight) / 2 + font.ascender - font.capHeight / 2
            caret.frame = CGRect(x: pad + lead + textW + caretGap, y: (capMid - caretH / 2).rounded(), width: caretW, height: caretH)
            let path = UIBezierPath()
            let open = t.groupOpen
            path.move(to: CGPoint(x: 0, y: open ? caretH : 0))
            path.addLine(to: CGPoint(x: caretW / 2, y: open ? 0 : caretH))
            path.addLine(to: CGPoint(x: caretW, y: open ? caretH : 0))
            caret.path = path.cgPath
        }
        CATransaction.commit()
        updateColors()
        titleLabel.frame = CGRect(x: pad + lead, y: 0, width: textW, height: h)
        rowButton.isEnabled = group.opens
        rowButton.accessibilityTraits = group.opens ? .button : .staticText
        // "4 updates: From Hermes, Delegated 1 task, To Hermes, To Hermes", or a single line's own words.
        rowButton.accessibilityLabel = group.count > 1 ? "\(group.count) updates: " + group.titles.joined(separator: ", ") : t.title
        rowButton.accessibilityValue = group.opens && !t.single ? (t.groupOpen ? "Expanded" : "Collapsed") : nil
        rowButton.accessibilityHint = !group.opens ? nil : t.single ? "Shows the step’s details"
            : group.count > 1 ? "Shows them" : "Shows the message"
    }

    private func link(at gr: UIGestureRecognizer) -> URL? {
        guard !card.isHidden, !thoughtText.isHidden else { return nil }
        let p = gr.location(in: thoughtText)
        return thoughtText.bounds.insetBy(dx: -6, dy: -6).contains(p) ? thoughtText.link(at: p) : nil
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === linkTap { return link(at: gestureRecognizer) != nil }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    @objc private func linkTapped(_ gr: UITapGestureRecognizer) {
        guard let url = link(at: gr) else { return }
        delegate?.chatCellOpen(url: url)
    }

    /// Each link in the opened text as a VoiceOver action on the row ("Open example.com").
    private func linkActions(_ string: NSAttributedString) -> [UIAccessibilityCustomAction]? {
        var actions: [UIAccessibilityCustomAction] = []
        string.enumerateAttribute(.chatLink, in: NSRange(location: 0, length: string.length)) { value, _, _ in
            guard let url = value as? URL else { return }
            actions.append(UIAccessibilityCustomAction(name: "Open \(url.host() ?? url.absoluteString)") { [weak self] _ in
                self?.delegate?.chatCellOpen(url: url)
                return true
            })
        }
        return actions.isEmpty ? nil : actions
    }

    private func configureSteps(_ t: ToolRowLayout, style: ChatStyle) {
        while stepViews.count < t.steps.count {
            let control = UIControl()
            let title = UILabel(), meta = UILabel(), sep = UIView()
            title.textColor = ChatPalette.label
            title.lineBreakMode = .byTruncatingTail
            meta.textAlignment = .right
            sep.backgroundColor = ChatPalette.separator
            // The step still running: the row's `breathe` spinner at its trailing end (a fixed-width glyph, still
            // under Reduce Motion), in the place a failed step's "Failed" takes.
            let working = GlyphSpinner(style: .breathe, color: ChatPalette.label3, size: HQFont.symbolSize(13, like: .footnote, cap: 22))
            working.isHidden = true
            working.isAccessibilityElement = false
            control.addSubview(title); control.addSubview(meta); control.addSubview(sep); control.addSubview(working)
            control.tag = stepViews.count
            control.addTarget(self, action: #selector(openStep(_:)), for: .touchUpInside)
            control.isAccessibilityElement = true
            control.accessibilityTraits = .button
            card.addSubview(control)
            stepViews.append((control, title, meta, sep, working))
        }
        firstStep = t.firstStep
        let hairline = 1 / max(traitCollection.displayScale, 1)
        for (i, entry) in stepViews.enumerated() {
            let (control, title, meta, sep, working) = entry
            guard i < t.steps.count else { control.isHidden = true; working.isHidden = true; continue }
            let step = t.steps[i]
            control.isHidden = false
            control.frame = step.frame
            let spins = t.live && step.live && step.meta == nil
            let spinW = spins ? style.toolGlyph + 4 : 0
            working.isHidden = !spins
            working.frame = CGRect(x: step.frame.width - spinW, y: ((step.frame.height - spinW) / 2).rounded(), width: spinW, height: spinW)
            let metaW = step.meta.map { ceil(($0 as NSString).size(withAttributes: [.font: style.toolMeta]).width) } ?? spinW
            meta.font = style.toolMeta
            meta.text = step.meta
            meta.textColor = ChatPalette.red
            meta.frame = CGRect(x: step.frame.width - metaW, y: 0, width: metaW, height: step.frame.height)
            title.font = style.tool
            title.text = step.title
            // The running step reads as fully as the finished ones; its spinner marks it.
            title.textColor = ChatPalette.label
            title.frame = CGRect(x: 0, y: 0, width: step.frame.width - metaW - (metaW > 0 ? 8 : 0), height: step.frame.height)
            sep.isHidden = i == 0 && t.showAllFrame == nil
            sep.frame = CGRect(x: 0, y: 0, width: step.frame.width, height: hairline)
            control.accessibilityLabel = step.title + (step.meta.map { ", " + $0 } ?? "")
        }
        configureStepFooters(t, style: style, hairline: hairline)
    }

    /// A long opened One Line card's "Show All N Steps" (the Steps sheet) and "Show Less" (closes the card), 44 pt rows
    /// in the card like its steps.
    private func configureStepFooters(_ t: ToolRowLayout, style: ChatStyle, hairline: CGFloat) {
        showAllRow.isHidden = t.showAllFrame == nil
        showLessRow.isHidden = t.showLessFrame == nil
        if let frame = t.showAllFrame {
            showAllRow.frame = frame
            showAllLabel.font = style.tool
            showAllLabel.text = "Show All \(t.stepCount) Steps"
            showAllLabel.frame = showAllRow.bounds
            showAllRow.accessibilityLabel = showAllLabel.text
        }
        if let frame = t.showLessFrame {
            showLessRow.frame = frame
            showLessLabel.font = style.tool
            showLessLabel.text = "Show Less"
            showLessLabel.frame = showLessRow.bounds
            showLessRule.frame = CGRect(x: 0, y: 0, width: frame.width, height: hairline)
            showLessRow.accessibilityLabel = "Show Less"
        }
    }

    @objc private func showAllSteps() { delegate?.chatCellShowAllSteps(rowId: rowId) }

    /// Running, as on the desktop: a tool's glyph gives way to the `breathe` spinner (a thought keeps its glyph; the
    /// desktop's thinking line has none to swap), and the title shimmers (V:message-parts.tsx:305, fallback.tsx:328).
    private func setLive(_ on: Bool) {
        live = on
        let spins = on && currentGlyph != .thinking
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.isHidden = spins || showsFace || isGroup
        CATransaction.commit()
        spinner.isHidden = !spins
        Shimmer.set(on, on: titleLabel)
        // Reduce Motion: the spinner is a still ⠿ and the title doesn't shimmer, so a live row (a thought's above all)
        // looked finished. A still accent dot before the chevron (or the meta) says it is still going; nothing moves.
        let still = on && HQMotion.reduced
        liveDot.isHidden = !still
        if still {
            let d: CGFloat = 7
            let end = (metaLabel.text?.isEmpty == false ? metaLabel.frame.minX : chevron.frame.minX) - 8
            liveDot.frame = CGRect(x: end - d, y: ((rowButton.bounds.height - d) / 2).rounded(), width: d, height: d)
            titleLabel.frame.size.width = max(0, min(titleLabel.frame.width, liveDot.frame.minX - 8 - titleLabel.frame.minX))
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        live = false
        liveDot.isHidden = true
        Shimmer.set(false, on: titleLabel)
        if hovering { hovering = false; rowButton.backgroundColor = .clear }
    }

    @objc private func toggle() {
        Haptics.play(.selection)
        delegate?.chatCellToggle(rowId: rowId)
    }

    @objc private func openStep(_ sender: UIControl) { delegate?.chatCellOpenStep(rowId: rowId, index: firstStep + sender.tag) }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let menu = delegate?.chatCellRowMenu(rowId: rowId, source: rowButton) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }

    @objc private func pressDown() {
        if showsBacking { pressBacking(true) } else { rowButton.backgroundColor = ChatPalette.fill4 }
    }
    @objc private func pressUp() {
        if showsBacking { pressBacking(false) }
        UIView.animate(withDuration: 0.2) { self.rowButton.backgroundColor = self.restingFill }   // motion-ok: colour only
    }

    /// [mac] Stress test 2026-10-31: a step, a group line or a delivery is a button, but nothing under the pointer said
    /// so (the transcript is left out of `PointerEffects`). The press's own shape takes the list rows' hover fill.
    private var hovering = false
    private var restingFill: UIColor {
        #if targetEnvironment(macCatalyst)
        if hovering && !showsBacking { return MacHover.rowFill }
        #endif
        return .clear
    }

    #if targetEnvironment(macCatalyst)
    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        hovering = (recognizer.state == .began || recognizer.state == .changed) && rowButton.isEnabled
        guard !rowButton.isTracking else { return }
        if showsBacking { hoverBacking(hovering) } else { rowButton.backgroundColor = restingFill }
    }

    #endif
}

// MARK: - One line of text (day separator, notice, captions)

final class ChatLineCell: ChatBaseCell {
    static let reuse = "line"
    private let text = TextDrawView()
    /// The tappable line's target ("Delivery Unconfirmed · Check").
    private let tap = UIControl()
    /// "Stopped before <Bot> replied" › Retry.
    private let retry = RetryCapsule()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        contentView.addSubview(text)
        tap.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        tap.addTarget(self, action: #selector(pressed), for: [.touchDown, .touchDragEnter])
        tap.addTarget(self, action: #selector(released), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        contentView.addSubview(tap)
        retry.isHidden = true
        retry.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        contentView.addSubview(retry)
        isAccessibilityElement = true
        // MENUS (spec 1x §8.4): web addresses in a slash command's output open like a bubble's links.
        let links = UITapGestureRecognizer(target: self, action: #selector(linkTapped(_:)))
        links.cancelsTouchesInView = false
        addGestureRecognizer(links)
        linkTap = links
    }

    private weak var linkTap: UITapGestureRecognizer?

    private func link(at gr: UIGestureRecognizer) -> URL? {
        let p = gr.location(in: text)
        return text.bounds.insetBy(dx: -6, dy: -6).contains(p) ? text.link(at: p) : nil
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === linkTap { return link(at: gestureRecognizer) != nil }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    @objc private func linkTapped(_ gr: UITapGestureRecognizer) {
        guard let url = link(at: gr) else { return }
        delegate?.chatCellOpen(url: url)
    }

    /// Each link in the line as a VoiceOver action ("Open example.com").
    private func linkActions(_ string: NSAttributedString) -> [UIAccessibilityCustomAction]? {
        var actions: [UIAccessibilityCustomAction] = []
        string.enumerateAttribute(.chatLink, in: NSRange(location: 0, length: string.length)) { value, _, _ in
            guard let url = value as? URL else { return }
            actions.append(UIAccessibilityCustomAction(name: "Open \(url.host() ?? url.absoluteString)") { [weak self] _ in
                self?.delegate?.chatCellOpen(url: url)
                return true
            })
        }
        return actions.isEmpty ? nil : actions
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ row: ChatRow, layout: RowLayout) {
        super.configure(row, layout: layout)
        guard case .line(let l) = layout.content else { return }
        text.frame = l.frame
        text.set(layout: l.text)
        text.alpha = 1
        placeBacking(Self.wordsFrame(l).insetBy(dx: -8, dy: -3), radius: 12)
        text.traitOverrides[PillInkTrait.self] = showsBacking   // [backdrop] its grey words in strong ink on the pill
        accessibilityLabel = l.text.text.string
        accessibilityCustomActions = linkActions(l.text.text)
        if let capsule = l.retryFrame, let target = l.retryTap {
            retry.isHidden = false
            retry.configure(capsule: capsule, target: target)
            isAccessibilityElement = false
            text.isAccessibilityElement = true
            text.accessibilityLabel = l.text.text.string
            accessibilityElements = [text, retry]
        } else {
            retry.isHidden = true
            isAccessibilityElement = true
            accessibilityElements = nil
        }
        if let frame = l.tapFrame {
            tap.isHidden = false
            tap.frame = frame
            accessibilityTraits = .button
            accessibilityHint = "Checks whether \(HostWord.phrase) got this message"
            accessibilityIdentifier = "chat.delivery-check"
        } else {
            tap.isHidden = true
            accessibilityTraits = .staticText
            accessibilityHint = nil
            accessibilityIdentifier = nil
        }
    }

    /// [backdrop] Where the line's words are drawn: its frame spans the chat, and TextKit places them in it (centred,
    /// at the start or at the end).
    static func wordsFrame(_ l: LineLayout) -> CGRect {
        let used = l.text.manager.usedRect(for: l.text.container)
        return used.offsetBy(dx: l.frame.minX, dy: l.frame.minY).integral
    }

    override func accessibilityActivate() -> Bool {
        guard !tap.isHidden else { return false }
        tapped()
        return true
    }

    @objc private func tapped() {
        Haptics.play(.selection)
        delegate?.chatCellCheckDelivery(rowId: rowId)
    }

    @objc private func pressed() { text.alpha = 0.5 }
    @objc private func released() { UIView.animate(withDuration: 0.15) { self.text.alpha = 1 } }   // motion-ok: opacity only

    @objc private func retryTapped() {
        Haptics.play(.light)
        delegate?.chatCellRetry(rowId: rowId)
    }
}

/// The Retry capsule: drawn at its capsule frame, touchable over its 44 pt target (spec 06 §5.6.3 DECISION).
final class RetryCapsule: UIControl {
    private let border = CAShapeLayer()
    private let glyph = UIImageView()
    private let label = UILabel()
    private var capsuleInSelf = CGRect.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        border.fillColor = nil
        border.lineWidth = 1
        layer.addSublayer(border)
        glyph.contentMode = .scaleAspectFit
        glyph.isUserInteractionEnabled = false
        addSubview(glyph)
        label.text = RetryCapsuleMetrics.title
        label.isUserInteractionEnabled = false
        addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = RetryCapsuleMetrics.title
        accessibilityTraits = .button
        accessibilityIdentifier = "chat.stopped-retry"
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: RetryCapsule, _) in view.recolor() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(capsule: CGRect, target: CGRect) {
        frame = target
        capsuleInSelf = capsule.offsetBy(dx: -target.minX, dy: -target.minY)
        let style = ChatStyleCache.shared.style(for: traitCollection.preferredContentSizeCategory)
        label.font = RetryCapsuleMetrics.font(style)
        let g = RetryCapsuleMetrics.glyph(style)
        glyph.image = UIImage(systemName: "arrow.clockwise", withConfiguration: UIImage.SymbolConfiguration(pointSize: g * 0.8, weight: .semibold))
        glyph.frame = CGRect(x: capsuleInSelf.minX + RetryCapsuleMetrics.padH, y: capsuleInSelf.midY - g / 2, width: g, height: g)
        let labelX = glyph.frame.maxX + RetryCapsuleMetrics.gap
        label.frame = CGRect(x: labelX, y: capsuleInSelf.minY, width: max(0, capsuleInSelf.maxX - RetryCapsuleMetrics.padH - labelX + 1),
                             height: capsuleInSelf.height)
        border.path = UIBezierPath(roundedRect: capsuleInSelf.insetBy(dx: 0.5, dy: 0.5), cornerRadius: capsuleInSelf.height / 2).cgPath
        recolor()
    }

    private func recolor() {
        let accent = ChatPalette.tint.resolvedColor(with: traitCollection)
        border.strokeColor = accent.withAlphaComponent(0.35).cgColor
        glyph.tintColor = accent
        label.textColor = accent
    }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.5 : 1 } }
}

// MARK: - Error card

final class ChatErrorCell: ChatBaseCell, UIContextMenuInteractionDelegate {
    static let reuse = "error"
    private let card = UIView()
    private let glyph = CAShapeLayer()
    private let title = TextDrawView()
    private let reason = TextDrawView()
    private let closeButton = UIButton(type: .system)
    private let detailsButton = UIButton(type: .system)
    /// The primary recovery (spec 06 §5.6.1): a capsule of tint 16 % over the cell colour, tint text, a 14 pt glyph.
    private let retryButton = UIButton(type: .system)
    private var copyText = ""

    /// Tint at 16 % over the cell colour (the page colour in light, the card's in dark: spec 06 §1.2's `#1C1C1E` is
    /// the default theme's card; a tinted dark theme's card keeps the capsule its own colour, audit 10-16).
    static let retryFill = UIColor { traits in
        let tint = ChatPalette.tint.resolvedColor(with: traits)
        let cell = (traits.userInterfaceStyle == .dark ? ChatPalette.grouped : ChatPalette.page).resolvedColor(with: traits)
        var (tr, tg, tb, ta): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (cr, cg, cb, ca): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        tint.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        cell.getRed(&cr, green: &cg, blue: &cb, alpha: &ca)
        let k: CGFloat = 0.16
        return UIColor(red: cr + (tr - cr) * k, green: cg + (tg - cg) * k, blue: cb + (tb - cb) * k, alpha: 1)
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        card.backgroundColor = ChatPalette.grouped
        card.layer.cornerRadius = HQShape.radius(14, .card)
        card.layer.cornerCurve = .continuous
        contentView.addSubview(card)
        glyph.fillColor = nil
        glyph.lineWidth = 1.8
        glyph.lineCap = .round
        glyph.path = ChatGlyph.error.path(size: 18)
        card.layer.addSublayer(glyph)
        card.addSubview(title)
        card.addSubview(reason)
        var close = UIButton.Configuration.plain()
        close.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        close.baseForegroundColor = ChatPalette.tintText
        closeButton.configuration = close
        closeButton.accessibilityLabel = "Close"
        closeButton.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        card.addSubview(closeButton)
        var details = UIButton.Configuration.plain()
        details.image = UIImage(systemName: "info.circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        details.imagePadding = 6
        details.baseForegroundColor = ChatPalette.tintText
        details.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        details.titleLineBreakMode = .byTruncatingTail
        detailsButton.configuration = details
        detailsButton.addTarget(self, action: #selector(detailsTapped), for: .touchUpInside)
        detailsButton.accessibilityIdentifier = "chat.error-details"
        card.addSubview(detailsButton)
        var retry = UIButton.Configuration.plain()
        retry.image = UIImage(systemName: "arrow.clockwise", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        retry.imagePadding = 6
        retry.baseForegroundColor = ChatPalette.tintText
        retry.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        retry.background.backgroundColor = ChatErrorCell.retryFill
        retry.cornerStyle = .capsule
        retry.titleLineBreakMode = .byTruncatingTail
        retryButton.configuration = retry
        retryButton.isHidden = true
        retryButton.accessibilityIdentifier = "chat.error-retry"
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        card.addSubview(retryButton)
        card.addInteraction(UIContextMenuInteraction(delegate: self))
        card.isAccessibilityElement = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (cell: ChatErrorCell, _) in
            cell.glyph.strokeColor = ChatPalette.alertRed.resolvedColor(with: cell.traitCollection).cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func configure(_ row: ChatRow, layout: RowLayout) {
        super.configure(row, layout: layout)
        guard case .error(let e) = layout.content else { return }
        card.frame = e.cardFrame
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glyph.frame = e.glyphFrame
        glyph.strokeColor = ChatPalette.alertRed.resolvedColor(with: traitCollection).cgColor
        CATransaction.commit()
        title.frame = e.titleFrame
        title.set(layout: e.title)
        reason.frame = e.reasonFrame
        reason.set(layout: e.reason)
        copyText = e.copyText
        closeButton.frame = e.closeFrame
        detailsButton.frame = e.detailsFrame
        let font = ChatStyleCache.shared.style(for: traitCollection.preferredContentSizeCategory).errorBody
        // The icons grow with the words beside them (14 pt beside 15 pt Subheadline at the default size).
        let icon = (font.pointSize * 14 / 15).rounded()
        var close = closeButton.configuration
        close?.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: icon, weight: .semibold))
        closeButton.configuration = close
        var details = detailsButton.configuration
        details?.attributedTitle = AttributedString("Details", attributes: AttributeContainer([.font: font]))
        details?.image = UIImage(systemName: "info.circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: icon, weight: .regular))
        detailsButton.configuration = details
        if let frame = e.retryFrame {
            retryButton.isHidden = false
            retryButton.frame = frame
            var retry = retryButton.configuration
            retry?.attributedTitle = AttributedString(e.chooseModel ? "Choose a Model" : RetryCapsuleMetrics.title, attributes: AttributeContainer([.font: font]))
            retry?.image = e.chooseModel ? nil : UIImage(systemName: "arrow.clockwise", withConfiguration: UIImage.SymbolConfiguration(pointSize: icon, weight: .semibold))
            retryButton.configuration = retry
            retryButton.accessibilityLabel = e.chooseModel ? "Choose a Model" : nil
            chooseModel = e.chooseModel
        } else {
            retryButton.isHidden = true
        }
        title.isAccessibilityElement = true
        title.accessibilityLabel = e.title.text.string + ". " + e.reason.text.string
        title.accessibilityTraits = .staticText
    }

    @objc private func dismissTapped() { delegate?.chatCellDismissError(rowId: rowId) }
    @objc private func detailsTapped() { delegate?.chatCellErrorDetails(rowId: rowId, details: copyText) }
    private var chooseModel = false
    @objc private func retryTapped() {
        Haptics.play(.light)
        if chooseModel { delegate?.chatCellChooseModel(); return }
        delegate?.chatCellRetry(rowId: rowId)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        let text = copyText
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [UIAction(title: "Copy Details", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = text
                Haptics.play(.success)
            }])
        }
    }
}

// MARK: - Waiting capsule (spec 06 §3.4)

/// [thinking] The bot's face, a 40×24 capsule in the bot bubble's colour with three typing dots, then "Ivy is thinking…"
/// in Footnote label-2 (owner, 2026-10-27; it was the desktop's dither square and "Waiting for <model>"). A timer joins
/// beside the words, and after 60 s with no step running they become "Ivy is still thinking…" / "still working…"
/// (`WaitingRow.longLabel`; owner, 2026-10-29: the desktop's "No reply yet" looked like a failure while the bot worked).
final class ChatWaitingCell: ChatBaseCell {
    static let reuse = "waiting"
    /// The typing dots: each brightens in turn, 0.2 s apart, every 1.2 s. Still (all at 60 %) under Reduce Motion.
    private let capsule = UIView()
    private let dots: [UIView] = (0..<3).map { _ in UIView() }
    private let label = UILabel()
    /// [thinking] How long it has waited, "· 0:12", from 10 s on (a quick reply never shows a counter), in the line's
    /// size and the quieter grey, steady-width digits (owner, 2026-10-27: the small blue "1s" read as a link).
    private let timerLabel = UILabel()
    private var timerShown = false
    private var waitLabel = ""
    private var longLabel: String?
    private var doing = false
    /// The room the words and the timer share (the layout's text width).
    private var room: CGFloat = 0
    private var since = Date()
    private var timer: Timer?
    /// [groups] A room's typing row: the label as it is, the member's face in the face column.
    private var plain = false
    private var face: HeadView?
    /// [thinking] The chat's own bot, leading the dots.
    private var botFace: HeadView?
    /// A tap opens the turn's steps (`WaitingRow.opensSteps`).
    private lazy var stepsTap = UITapGestureRecognizer(target: self, action: #selector(showSteps))

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        capsule.backgroundColor = ChatPalette.botBubble
        capsule.layer.cornerCurve = .continuous
        contentView.addSubview(capsule)
        for dot in dots {
            dot.backgroundColor = ChatPalette.label2
            dot.layer.cornerRadius = 3
            capsule.addSubview(dot)
        }
        label.textColor = ChatPalette.label2
        label.lineBreakMode = .byTruncatingTail
        contentView.addSubview(label)
        timerLabel.textColor = ChatPalette.label3
        timerLabel.alpha = 0
        contentView.addSubview(timerLabel)
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
        contentView.addGestureRecognizer(stepsTap)
        #if targetEnvironment(macCatalyst)
        contentView.addInteraction(stepsTip)
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// [mac] Stress test 2026-10-31: nothing under the pointer said the thinking row opens its steps.
    private let stepsTip = UIToolTipInteraction(defaultToolTip: "Show Steps")
    #endif

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func showSteps() {
        Haptics.play(.selection)
        delegate?.chatCellShowLiveSteps()
    }

    override func accessibilityActivate() -> Bool {
        guard stepsTap.isEnabled else { return false }
        showSteps()
        return true
    }

    override func configure(_ row: ChatRow, layout: RowLayout) {
        super.configure(row, layout: layout)
        guard case .waiting(let w) = layout.content, case .waiting(let spec) = row.kind else { return }
        stepsTap.isEnabled = spec.opensSteps && !spec.plain
        #if targetEnvironment(macCatalyst)
        stepsTip.isEnabled = stepsTap.isEnabled   // [mac] 2026-10-31: the pointer's word for the click
        #endif
        accessibilityTraits = stepsTap.isEnabled ? [.updatesFrequently, .button] : .updatesFrequently
        accessibilityHint = stepsTap.isEnabled ? "Shows every step" : nil
        // [backdrop] On a picture the pill keeps the bubbles' column: what it holds moves in by its inset, and the words
        // leave room for its far end.
        let inset = Backdrop.chats.shows ? Self.pillInset : 0
        capsule.frame = w.capsule.offsetBy(dx: inset, dy: 0)
        capsule.layer.cornerRadius = w.capsule.height / 2
        // On the pill the dots stand on the pill in the words' ink, with no grey capsule of their own (owner, 2026-11-01:
        // the solid capsule inside the glass "looks cheap"), 12 pt in from its round end and 11 pt before the words.
        capsule.backgroundColor = inset > 0 ? .clear : ChatPalette.botBubble
        let side: CGFloat = 6, spacing: CGFloat = 5
        var x = inset > 0 ? 12 - inset : ((w.capsule.width - (3 * side + 2 * spacing)) / 2).rounded()
        for dot in dots {
            dot.backgroundColor = inset > 0 ? ChatPalette.label : ChatPalette.label2
            dot.frame = CGRect(x: x, y: ((w.capsule.height - side) / 2).rounded(), width: side, height: side)
            x += side + spacing
        }
        let notice = ChatStyleCache.shared.style(for: traitCollection.preferredContentSizeCategory).notice
        label.font = notice
        timerLabel.font = HQFont.monoDigitFace(ofSize: notice.pointSize)
        label.frame = w.textFrame.offsetBy(dx: inset, dy: 0)
        room = max(0, w.textFrame.width - (inset > 0 ? inset + Self.pillTrail : 0))
        waitLabel = spec.label
        longLabel = spec.longLabel
        doing = spec.doing                                                                       // [toolnow]
        since = spec.since
        plain = spec.plain                                                                         // [groups]
        if let sender = spec.sender {
            let view = face ?? {
                let made = HeadView(side: TextLayout.senderFace)
                made.isUserInteractionEnabled = false
                contentView.addSubview(made)
                face = made
                return made
            }()
            view.isHidden = false
            view.frame = CGRect(x: ChatMetrics.sideInset, y: w.capsule.midY - TextLayout.senderFace / 2,
                                width: TextLayout.senderFace, height: TextLayout.senderFace)
            view.configure(raw: sender.head, profile: sender.profile)
        } else {
            face?.isHidden = true
        }
        if let frame = w.face, let bot = spec.bot {                                               // [thinking]
            let view = botFace ?? {
                let made = HeadView(side: WaitingLayout.face)
                made.isUserInteractionEnabled = false
                contentView.addSubview(made)
                botFace = made
                return made
            }()
            view.isHidden = false
            view.frame = frame.offsetBy(dx: inset, dy: 0)
            view.configure(raw: bot.head, profile: bot.profile)
        } else {
            botFace?.isHidden = true
        }
        accessibilityIdentifier = plain ? "chat.typing" : "chat.waiting"
        tick(force: true)
        animate()
    }

    /// `turnStatusCopy(label, elapsed)`: what VoiceOver hears.
    static func words(label: String, long: String? = nil, elapsed: TimeInterval, doing: Bool = false) -> String {
        let seconds = max(0, Int(elapsed))
        let text = line(label: label, long: long, seconds: seconds, doing: doing)
        if seconds >= 10 { return text + String(format: " · %d:%02d", seconds / 60, seconds % 60) }
        return text
    }

    /// The words before the timer: `long` takes over at 60 s unless a step is running.
    static func line(label: String, long: String?, seconds: Int, doing: Bool) -> String {
        seconds >= 60 && !doing ? (long ?? label) : label
    }

    /// The counter beside the line: nothing for the first 10 s, then "· 0:12", "· 1:05" (one format, so the width
    /// never jumps at a minute), the same clock VoiceOver reads (`words`).
    static func elapsed(_ seconds: Int) -> String {
        seconds < 10 ? "" : String(format: "· %d:%02d", seconds / 60, seconds % 60)
    }

    private func tick(force: Bool = false) {
        let seconds = max(0, Int(Date().timeIntervalSince(since)))
        let text = plain ? waitLabel : Self.line(label: waitLabel, long: longLabel, seconds: seconds, doing: doing)
        let time = plain ? "" : Self.elapsed(seconds)
        // [toolnow] A long step's words end in "…" before the timer, which always shows whole (owner, 2026-10-28: the
        // step ran under the timer and off the row).
        let reserve: CGFloat = time.isEmpty ? 0 : ceil((time as NSString).size(withAttributes: [.font: timerLabel.font as Any]).width) + 5
        if label.text != text || force || (time.isEmpty != (timerLabel.text ?? "").isEmpty) {
            label.text = text
            let natural = ceil(label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: label.frame.height)).width)
            label.frame.size.width = max(0, min(room - reserve, natural))
            Shimmer.set(true, on: label)                      // the desktop's waiting hint shimmers (V:thread/status.tsx:55)
        }
        if timerLabel.text != time || force {
            timerLabel.text = time
            timerLabel.sizeToFit()
        }
        timerLabel.frame.origin = CGPoint(x: label.frame.maxX + 5, y: (label.frame.midY - timerLabel.frame.height / 2).rounded())
        let show = !time.isEmpty
        var widened = false
        if show != timerShown || force {
            let fade = show && !timerShown && !force && !HQMotion.reduced
            timerShown = show
            if fade {
                widened = true
                // The pill widens as the timer fades in.
                UIView.animate(withDuration: 0.3) {                                // HQMotion.reduced checked above
                    self.timerLabel.alpha = 1
                    self.placePill(force: false)
                }
            } else {
                timerLabel.alpha = show ? 1 : 0
            }
        }
        if !widened { placePill(force: force) }
        accessibilityLabel = plain ? waitLabel : Self.words(label: waitLabel, long: longLabel, elapsed: Date().timeIntervalSince(since), doing: doing)
    }

    /// [backdrop] On a chat background, one frosted pill (glass until 2026-11-01) holds the dots, the words and the timer (owner, 2026-11-01: "with a
    /// background, the tool calls at the bottom are hard to read"), 3 pt round where the dots' capsule sits.
    /// It follows the words as the step changes. On it the words and the timer take the primary label: the page's label-2
    /// and label-3 measured 3.9:1 and less on dark glass over a picture, and 80–85 % ink still 4.1–4.2:1 (spec 06 §8 asks
    /// 4.5:1).
    private static let pillInset: CGFloat = 3, pillTrail: CGFloat = 10
    private var pillRect: CGRect?
    private func placePill(force: Bool) {
        let lead = (botFace.flatMap { $0.isHidden ? nil : $0.frame.minX } ?? capsule.frame.minX) - Self.pillInset
        let trail = (timerShown ? timerLabel.frame.maxX : label.frame.maxX) + Self.pillTrail
        let h = max(capsule.frame.height, ceil(label.font.lineHeight)) + 2 * Self.pillInset
        let rect = CGRect(x: lead, y: (capsule.frame.midY - h / 2).rounded(), width: trail - lead, height: h)
        guard force || rect != pillRect else { return }
        pillRect = rect
        placeBacking(rect, radius: h / 2)
        label.textColor = showsBacking ? ChatPalette.label : ChatPalette.label2
        timerLabel.textColor = showsBacking ? ChatPalette.label : ChatPalette.label3
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        animate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The dots brighten in turn on one shared clock, so a re-used cell doesn't restart the wave.
    private func animate() {
        guard !HQMotion.reduced else {
            for dot in dots { dot.layer.removeAnimation(forKey: "typing"); dot.alpha = 0.6 }
            return
        }
        let period: CFTimeInterval = 1.2
        for (index, dot) in dots.enumerated() where dot.layer.animation(forKey: "typing") == nil {
            dot.alpha = 1
            let wave = CAKeyframeAnimation(keyPath: "opacity")   // HQMotion.reduced checked above
            wave.values = [0.3, 1, 0.3, 0.3]
            wave.keyTimes = [0, 0.25, 0.5, 1]
            wave.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut),
                                    CAMediaTimingFunction(name: .linear)]
            wave.duration = period
            wave.repeatCount = .infinity
            wave.timeOffset = fmod(CACurrentMediaTime() - Double(index) * 0.2 + period, period)
            wave.isRemovedOnCompletion = false
            dot.layer.add(wave, forKey: "typing")
        }
    }
}

// MARK: - Action row (latest reply)

/// Under the latest settled reply (spec 06 §2.5; S:ui-chat/composer.tsx CHT-05): Copy · Regenerate · More, 44 pt circles
/// with 20 pt glyphs in label-2 and a Fill 3 press fill; Copy's glyph turns into a check for 1.5 s after copying. More
/// holds what didn't fit (Share, Select Text, Branch in New Chat). [talk] Read Aloud sits second, as on the web: Copy ·
/// Read Aloud · Regenerate · More (docs/spec/3x-talk.md §7.1).
final class ChatActionsCell: ChatBaseCell {
    static let reuse = "actions"
    private let readButton = UIButton(type: .custom)
    private let readSpinner = UIActivityIndicatorView(style: .medium)
    private var readState: ReadAloudCenter.Button?
    private let copyButton = UIButton(type: .custom)
    private let regenerateButton = UIButton(type: .custom)
    private let moreButton = UIButton(type: .custom)
    private var copyText = ""
    private var restore: DispatchWorkItem?
    /// [transcript] How long the turn took, at the trailing edge (docs/spec/3x-transcript.md §6.6).
    private let durationLabel = UILabel()
    private var buttonsMaxX: CGFloat = 0
    private var buttonsMidY: CGFloat = 0

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        durationLabel.textColor = ChatPalette.label2
        durationLabel.textAlignment = .right
        durationLabel.isAccessibilityElement = true
        durationLabel.accessibilityIdentifier = "chat.turn-duration"
        durationLabel.isHidden = true
        contentView.addSubview(durationLabel)
        for (button, label, id) in [(copyButton, "Copy", "chat.copy-reply"), (readButton, "Read Aloud", "chat.read-reply"),
                                    (regenerateButton, "Regenerate", "chat.regenerate-reply"), (moreButton, "More", "chat.reply-more")] {
            button.layer.cornerRadius = 22
            button.tintColor = ChatPalette.label2
            button.accessibilityLabel = label
            button.accessibilityIdentifier = id
            // [a11y] The icons keep their size at the accessibility text sizes; a hold shows one large, named.
            button.showsLargeContentViewer = true
            button.largeContentTitle = label
            button.scalesLargeContentImage = true
            button.addInteraction(UILargeContentViewerInteraction())
            button.addTarget(self, action: #selector(pressed(_:)), for: [.touchDown, .touchDragEnter])
            button.addTarget(self, action: #selector(released(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
            contentView.addSubview(button)
        }
        setGlyph("doc.on.doc")
        regenerateButton.setImage(glyph("arrow.clockwise"), for: .normal)
        moreButton.setImage(glyph("ellipsis"), for: .normal)
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)
        regenerateButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            Haptics.play(.selection)
            self.delegate?.chatCellRegenerate(rowId: self.rowId)
        }, for: .touchUpInside)
        moreButton.showsMenuAsPrimaryAction = true
        // [talk]
        readSpinner.hidesWhenStopped = true
        readSpinner.isUserInteractionEnabled = false
        readButton.addSubview(readSpinner)
        readButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.delegate?.chatCellToggleReadAloud(rowId: self.rowId)
        }, for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// [talk] The button's three looks: the speaker glyph; a spinner while the audio is fetched; a tinted Stop that
    /// pulses while this reply is being read.
    func refreshReadAloud() {
        let state = delegate?.chatCellReadAloud(rowId: rowId)
        readButton.isHidden = state == nil
        guard let state, state != readState else { readState = state; return }
        readState = state
        readButton.accessibilityLabel = state.label
        readButton.largeContentTitle = state.label
        readButton.layer.removeAnimation(forKey: "pulse")
        switch state {
        case .idle:
            readSpinner.stopAnimating()
            readButton.tintColor = ChatPalette.label2
            readButton.setImage(glyph("speaker.wave.2"), for: .normal)
        case .preparing:
            readButton.setImage(nil, for: .normal)
            readSpinner.startAnimating()
        case .speaking:
            readSpinner.stopAnimating()
            readButton.tintColor = ChatPalette.tint
            readButton.setImage(glyph("stop.circle"), for: .normal)   // the outline the hold menu uses, at the row's weight
            guard !HQMotion.reduced else { break }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.55
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            readButton.layer.add(pulse, forKey: "pulse")
        }
    }

    /// [a11y] 17 pt at the standard sizes; grows with the text up to 26 pt, which still sits inside the 44 pt circle
    /// (stress round 2: the icons stayed small under 40 pt message text).
    static func glyphPointSize(for category: UIContentSizeCategory) -> CGFloat {
        // [ui-sizing 2026-11-09] × UI Scale too (iPhone and iPad): at 150 % they stayed 17 pt under 25 pt words.
        let scaled = UIFontMetrics(forTextStyle: .body).scaledValue(for: 17, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
            * HQFont.glyphScale
        return min(26, max(17, scaled.rounded()))
    }

    private func glyph(_ name: String) -> UIImage? {
        let size = Self.glyphPointSize(for: traitCollection.preferredContentSizeCategory)
        return UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .regular))
    }

    override func configure(_ row: ChatRow, layout: RowLayout) {
        super.configure(row, layout: layout)
        guard case .actions(let a) = layout.content, case .actions(let spec) = row.kind else { return }
        copyButton.frame = a.copyFrame
        copyText = spec.copyText
        restore?.cancel()
        setGlyph("doc.on.doc")
        copyButton.accessibilityLabel = "Copy"   // a reused row isn't "Copied"
        // [talk] Read Aloud takes the second place; the others move one 48 pt step along.
        readState = nil
        readButton.setImage(nil, for: .normal)
        readButton.frame = a.copyFrame.offsetBy(dx: 48, dy: 0)
        readSpinner.center = CGPoint(x: 22, y: 22)
        refreshReadAloud()
        let step: CGFloat = readButton.isHidden ? 0 : 48
        regenerateButton.setImage(glyph("arrow.clockwise"), for: .normal)   // [a11y] at the current text size
        moreButton.setImage(glyph("ellipsis"), for: .normal)
        // MENUS: Regenerate and More beside Copy, when the chat offers them.
        let regenerate = delegate?.chatCellOffersRegenerate ?? false
        regenerateButton.isHidden = !regenerate
        regenerateButton.frame = a.copyFrame.offsetBy(dx: 48 + step, dy: 0)
        let more = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self, let menu = self.delegate?.chatCellReplyMore(rowId: self.rowId, source: self.moreButton) else { completion([]); return }
            completion(menu.children)
        }])
        moreButton.menu = more
        moreButton.isHidden = !regenerate
        moreButton.frame = a.copyFrame.offsetBy(dx: (regenerate ? 96 : 48) + step, dy: 0)
        // [transcript] The duration mark.
        buttonsMaxX = (regenerate ? moreButton.frame : readButton.isHidden ? copyButton.frame : readButton.frame).maxX
        buttonsMidY = a.copyFrame.midY
        durationLabel.text = spec.duration
        durationLabel.accessibilityLabel = spec.durationSpoken
        durationLabel.font = HQFont.face(ofSize: min(HQFont.preferred(.caption1, compatibleWith: traitCollection).pointSize, 20))
        placeDuration()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeDuration()
    }

    /// At the trailing edge, level with the buttons; left out when the row is too narrow for the buttons and the mark.
    private func placeDuration() {
        guard let text = durationLabel.text, !text.isEmpty else { durationLabel.isHidden = true; return }
        let size = durationLabel.sizeThatFits(CGSize(width: 200, height: 44))
        let column = bounds.width - 2 * ReadableColumn.fit(pane: bounds.width).margin   // [m9/ipad] the readable column
        let x = column - ChatMetrics.sideInset - 6 - size.width
        durationLabel.isHidden = x < buttonsMaxX + 12
        durationLabel.frame = CGRect(x: x, y: buttonsMidY - size.height / 2, width: size.width, height: size.height).integral
    }

    private func setGlyph(_ name: String) {
        copyButton.setImage(glyph(name), for: .normal)
    }

    @objc private func pressed(_ sender: UIButton) { sender.backgroundColor = ChatPalette.fill3 }
    @objc private func released(_ sender: UIButton) { UIView.animate(withDuration: 0.15) { sender.backgroundColor = .clear } }   // motion-ok: colour only

    @objc private func copyTapped() {
        UIPasteboard.general.string = copyText
        Haptics.play(.success)
        setGlyph("checkmark")
        copyButton.accessibilityLabel = "Copied"
        restore?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.setGlyph("doc.on.doc")
            self?.copyButton.accessibilityLabel = "Copy"
        }
        restore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

/// One tap on code copies it: the pasteboard, a success tap, "Copied" in the HUD and, on a card, its check.
enum ChatTapCopy {
    static func copy(_ text: String, from block: BlockView) {
        UIPasteboard.general.string = text
        Haptics.play(.success)
        block.showCopied()
        MenusHUD.show("Copied", in: block.window)
        _ = HQAnnounce.say("Copied")
    }
}

/// [perf] A bubble whose VoiceOver label is built when an accessibility client reads it, not when the cell is
/// configured. (`accessibilityLabelBlock` isn't usable: it exists only once the accessibility runtime has loaded.)
final class SpokenLabelView: UIView {
    var spoken: (() -> String?)?

    override var accessibilityLabel: String? {
        get { spoken?() ?? super.accessibilityLabel }
        set { super.accessibilityLabel = newValue }
    }
}

/// The words of a bubble with photos or controls, labelled the same lazy way (`SpokenLabelView`).
final class SpokenLabelElement: UIAccessibilityElement {
    var spoken: (() -> String?)?

    override var accessibilityLabel: String? {
        get { spoken?() ?? super.accessibilityLabel }
        set { super.accessibilityLabel = newValue }
    }
}

/// [glass-bubbles] Chat bubbles as Liquid Glass (Theme › Chat Bubbles › Glass, the iOS look; owner 2026-11-01). The
/// glass carries the skin's own bubble colour, so a plain page still shows that skin's bubble and a Chat Background shows
/// through it: replies at 55 %, yours at 85 % (white text keeps 4.5:1 on its colour), both at 90 % under Increase
/// Contrast. Untinted glass was tried first: clear glass failed 4.5:1 over a busy picture, and plain glass drew every skin's
/// replies the same white. Cards of rows (changed files, an opened run) stay solid (spec 06 §8 rule 5).
nonisolated enum GlassBubbles {
    static let replyTint: CGFloat = 0.55
    static let ownTint: CGFloat = 0.85
    static let contrastTint: CGFloat = 0.9

    /// [mac] Offered on the Mac too (owner 2026-11-09: "Can you do Liquid Glass on mac?"). It was left out after Catalyst
    /// drew the glass without its tint (2026-11-01, macOS 27 Debug build: your messages came out the replies' grey); on
    /// macOS 27.0.1 the tint draws (your messages blue at 85 %, the replies the skin's grey), so the Mac has the same three
    /// styles. A second tint laid inside the glass, as the sidebar's panel has, drew them twice as strong.
    static var offered: Bool { true }
    /// Glass is on (and the look is the iOS one), and Reduce Transparency is off.
    static var applies: Bool { offered && ThemeTable.glassBubbles && !HQAccessibility.reduceTransparency }

    /// `replyTint`: a skin's own share for replies (`SkinOwnLook.replyGlassTint`) instead of `replyTint`.
    static func tint(_ colour: UIColor, mine: Bool, increaseContrast: Bool, replyTint ownReply: CGFloat? = nil) -> UIColor {
        let alpha = increaseContrast ? contrastTint : mine ? ownTint : ownReply ?? replyTint
        return colour.withAlphaComponent(colour.cgColor.alpha * alpha)
    }

    /// The outline's corners in screen terms (`BubbleShape`): glass has no tail, so all four are Theme › Bubble Corners.
    static func corners(_ key: BubbleShape.Key) -> (topLeft: CGFloat, topRight: CGFloat, bottomLeft: CGFloat, bottomRight: CGFloat) {
        let round = min(ChatMetrics.bubbleRadius, min(key.width, key.height) / 2)
        return (round, round, round, round)
    }

    // MARK: [reply-backing] Tall bubbles

    // Tester 2026-11-09, Glass bubbles over a Chat Background: "When I scroll sometimes the background for the
    // reply just vanishes and it shows just the chat background", never in a screenshot or recording (Tinted and Solid
    // were fine). The glass was the whole bubble: a long reply's is several screens tall, and the phone at times left
    // it out while scrolling; captures, drawn apart from the screen, still had it. The simulator never dropped it. A
    // bubble taller than the screen now has glass only on its part on screen and `sliceMargin` past each edge, square
    // where it is cut, so the cut's corners and rim are never seen; a shorter one keeps its glass whole, as before.

    /// How far past the screen's edges a tall bubble's glass reaches: a row that moves before the next realign (a cell
    /// laid out after the table) still has its glass under it, and the cut stays off screen.
    static let sliceMargin: CGFloat = 64

    /// The part of a bubble its glass covers, in the bubble's terms, and whether it is cut off at the top or bottom.
    struct Slice: Equatable {
        var rect: CGRect
        var cutTop: Bool
        var cutBottom: Bool
    }

    /// `bubble` whole when it is no taller than `shown` (the window in the bubble's terms; nil: not in one), else its
    /// rows on screen and `sliceMargin` either side.
    static func slice(bubble: CGRect, shown: CGRect?) -> Slice {
        guard let shown, bubble.height > shown.height else { return Slice(rect: bubble, cutTop: false, cutBottom: false) }
        let top = max(bubble.minY, shown.minY - sliceMargin)
        let bottom = min(bubble.maxY, shown.maxY + sliceMargin)
        guard bottom > top else {
            // Off screen: nothing to draw.
            let y = min(max(top, bubble.minY), bubble.maxY)
            return Slice(rect: CGRect(x: bubble.minX, y: y, width: bubble.width, height: 0), cutTop: true, cutBottom: true)
        }
        return Slice(rect: CGRect(x: bubble.minX, y: top, width: bubble.width, height: bottom - top),
                     cutTop: top > bubble.minY, cutBottom: bottom < bubble.maxY)
    }

    /// Bubbles drawing glass now: every scroll step places a tall one's glass again.
    @MainActor private static let live = NSHashTable<BubbleShapeView>.weakObjects()

    @MainActor static func track(_ bubble: BubbleShapeView, _ on: Bool) {
        if on { live.add(bubble) } else { live.remove(bubble) }
    }

    /// The chat table laid out (a scroll step, a row moved): every glass bubble on the screen places its glass again.
    @MainActor static func realign() {
        guard live.count > 0 else { return }
        for bubble in live.allObjects where bubble.window != nil { bubble.placeGlass() }
    }
}
