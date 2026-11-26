// A page card: an HTML page a bot hands over alone on its line (`::preview{file="…"}`, the desktop app's inline page,
// or `MEDIA:/…/page.html`) in a settled reply. The desktop runs the page live in the reply; here the card shows a
// picture of the page (`PageSnapshots`) over its name, and a tap opens it live (`HTMLPageSheet`), where its buttons
// work. The card's size is fixed from the start, so the picture arriving never moves the chat. Owner, 2026-10-31:
// a bot's follow-up chart drew as a raw `::preview{…}` line.

import UIKit

final class PageCardView: UIControl {
    /// The Mac's reading column is much wider than a phone's: a bigger card there, so the chart reads.
    #if targetEnvironment(macCatalyst)
    nonisolated static let pictureHeight: CGFloat = 260
    nonisolated static let widest: CGFloat = 480
    #else
    nonisolated static let pictureHeight: CGFloat = 200
    nonisolated static let widest: CGFloat = 340
    #endif
    nonisolated static let padH: CGFloat = 12
    nonisolated static let padV: CGFloat = 9

    nonisolated static func height(style: ChatStyle) -> CGFloat {
        pictureHeight + padV + style.bodyLineHeight + 2 + style.timeLineHeight + padV
    }

    /// [page-fold] A card folded to its caption (the page is handed over again further down).
    nonisolated static func foldedHeight(style: ChatStyle) -> CGFloat {
        padV + style.bodyLineHeight + 2 + style.timeLineHeight + padV
    }

    nonisolated static func width(maxText: CGFloat) -> CGFloat { min(maxText, widest) }

    var onOpen: ((MediaRef) -> Void)?
    /// The card's `#media:` link (a hold gives the page's own menu: Open, Pin, Share…, Copy Path).
    var link: URL? { ref.flatMap(MarkdownMedia.linkURL) }
    private var ref: MediaRef?
    /// [pins] A pin on the picture's corner while the page is pinned to Artifacts.
    private let pinBadge = UIImageView(image: UIImage(systemName: "pin.fill"))
    private var context: MediaContext?
    private var themeKey = ""
    /// [page-fold] Only the caption shows: a later message hands the page over again.
    private var folded = false
    /// [page-cards] The reply that hands the page over is still arriving: the page's shape, no picture yet (the bot
    /// may still be writing the file).
    private var building = false
    private let pictureFrame = UIView()
    private let picture = UIImageView()
    /// [page-refine] Until the page is pictured: the shape of a page with a soft light crossing it, not a grey chart
    /// glyph that read as "this is a chart" on every page, drawn or not (owner 2026-11-17, Grok Bot's card).
    private let skeleton = PageSkeletonView()
    private let rule = UIView()
    private let glyph = UIImageView(image: UIImage(systemName: "doc.richtext"))
    /// [page-refine] At the caption's end: the card opens bigger. It stands in for the "Tap to open" the hint used to say.
    private let openGlyph = UIImageView(image: UIImage(systemName: "arrow.up.left.and.arrow.down.right"))
    private let nameLabel = UILabel()
    private let hintLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        picture.contentMode = .scaleToFill
        pictureFrame.clipsToBounds = true
        pictureFrame.backgroundColor = ChatPalette.page
        pictureFrame.addSubview(picture)
        openGlyph.contentMode = .center
        openGlyph.tintColor = ChatPalette.label3
        openGlyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        rule.backgroundColor = ChatPalette.separator
        glyph.contentMode = .scaleAspectFit
        glyph.tintColor = ChatPalette.label2
        nameLabel.textColor = ChatPalette.label
        nameLabel.lineBreakMode = .byTruncatingMiddle
        hintLabel.textColor = ChatPalette.label2
        hintLabel.lineBreakMode = .byTruncatingMiddle
        pinBadge.contentMode = .center
        pinBadge.tintColor = .white
        pinBadge.backgroundColor = ChatPalette.orange
        pinBadge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        pinBadge.isHidden = true
        for view in [pictureFrame, skeleton, rule, glyph, nameLabel, hintLabel, openGlyph, pinBadge] as [UIView] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "Opens the page"
        accessibilityIdentifier = "chat.page-card"
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        PointerEffects.surface(self)   // [mac] Feel list B: lit under the pointer, deeper while pressed
        NotificationCenter.default.addObserver(self, selector: #selector(turnEnded(_:)), name: PageSnapshots.turnEnded, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pinsChanged), name: ArtifactPins.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(headLearnt), name: PageSnapshots.headLearnt, object: nil)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self, UITraitAccessibilityContrast.self]) { (card: PageCardView, _) in
            let nextKey = HTMLPageSheet.themeKey(card.traitCollection)
            guard nextKey != card.themeKey else { return }
            card.themeKey = nextKey
            if card.ref != nil && !card.folded { card.loadPicture() }
        }
    }

    @objc private func headLearnt() {
        if let ref { showName(ref, context: context) }
    }

    @objc private func pinsChanged() { showPinned() }

    private func showPinned() {
        guard let context, let path = ref?.attachment.gatewayPath else { pinBadge.isHidden = true; return }
        let pinned = ArtifactPins.of(accountId: context.accountId).isPinned(profile: context.profile, value: path)
        pinBadge.isHidden = !pinned || folded
        accessibilityValue = pinned ? "Pinned" : nil
    }

    @objc private func turnEnded(_ note: Notification) {
        guard (note.object as? ContextBox)?.context == context, !folded else { return }
        loadPicture()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isHighlighted: Bool { didSet { alpha = PointerEffects.dim(isHighlighted, to: 0.6) } }

    func configure(_ ref: MediaRef, context: MediaContext?, style: ChatStyle, folded: Bool = false, building: Bool = false) {
        layer.cornerRadius = HQShape.radius(12, .card)
        layer.cornerCurve = .continuous
        nameLabel.font = style.bodyBold
        hintLabel.font = style.time
        let nextThemeKey = HTMLPageSheet.themeKey(traitCollection)
        #if DEBUG
        let building = building || UserDefaults.standard.bool(forKey: "HQDebugPageBuilding")   // the wait, held for a picture
        #endif
        let same = self.ref == ref && self.context == context && themeKey == nextThemeKey && self.folded == folded && self.building == building
        self.folded = folded
        self.building = building
        showName(ref, context: context)
        openGlyph.image = UIImage(systemName: folded ? "arrow.down" : "arrow.up.left.and.arrow.down.right")
        for view in [pictureFrame, rule] as [UIView] { view.isHidden = folded }
        if folded { skeleton.vanish(animated: false) }
        setNeedsLayout()
        guard !same else { showPinned(); return }
        self.ref = ref
        self.context = context
        themeKey = nextThemeKey
        showPinned()
        if folded { return }
        if building, picture.image == nil { show(nil) } else { loadPicture() }
    }

    /// [page-refine] The page's own title over its file ("Replies per 100 follow-ups" over "followups.html") once the
    /// page has been read; the file's name until then, and for a page with no title.
    private func showName(_ ref: MediaRef, context: MediaContext?) {
        let file = ref.attachment.name
        let title = context.flatMap { context in ref.attachment.gatewayPath.flatMap { PageSnapshots.shared.head(path: $0, context: context)?.title } }
        let named = title.map { !$0.isEmpty && $0.caseInsensitiveCompare(file) != .orderedSame } ?? false
        nameLabel.text = named ? title : file
        // What the second line says: folded, where the page went; while the reply arrives, that it is on its way.
        let kind = folded ? "Updated below" : building && picture.image == nil ? "Building page…" : "Interactive page"
        hintLabel.text = named && !folded ? "\(kind) · \(file)" : kind
        accessibilityLabel = "Page, \(named ? "\(title ?? file), \(file)" : file)\(folded ? ", updated below" : "")"
    }

    func reset() {
        ref = nil
        context = nil
        picture.image = nil
        pinBadge.isHidden = true
    }

    private func loadPicture() {
        guard let ref, let context, let path = ref.attachment.gatewayPath else { show(nil); return }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HQDebugPageSkeleton") { show(nil); return }   // the wait, held for a picture
        #endif
        let snapshots = PageSnapshots.shared
        let traits = traitCollection
        if let hit = snapshots.cached(path: path, context: context, traits: traits) { show(hit); return }
        // The last picture stays up while the new one draws (no flash after every turn).
        if picture.image == nil { show(nil) }
        let wanted = snapshots.key(path: path, context: context, traits: traits)
        snapshots.picture(path: path, name: ref.attachment.name, context: context, traits: traits) { [weak self] image in
            guard let self, let current = self.ref, let ctx = self.context, let p = current.attachment.gatewayPath,
                  snapshots.key(path: p, context: ctx, traits: self.traitCollection) == wanted else { return }
            self.showName(current, context: ctx)   // the read that drew the picture found the page's title
            if let image { self.show(image, fresh: true) } else if self.picture.image == nil { self.show(nil, failed: true) }
        }
    }

    /// `fresh`: the picture has just been drawn (it fades in over the skeleton); `failed`: the page couldn't be
    /// pictured (the skeleton stops: nothing is coming).
    private func show(_ image: UIImage?, fresh: Bool = false, failed: Bool = false) {
        let first = picture.image == nil
        picture.image = image
        if image != nil {
            skeleton.vanish(animated: fresh)
            if fresh, first, !HQMotion.reduced {
                picture.alpha = 0
                UIView.animate(withDuration: HQMotion.fade) { self.picture.alpha = 1 }   // motion-ok: a fade
            }
        } else if failed {
            skeleton.vanish()
        } else {
            skeleton.appear()
        }
        // Around the picture, the page's own colour (a white page in a dark chat isn't a white box in a dark frame).
        pictureFrame.backgroundColor = image.flatMap(Self.cornerColor) ?? ChatPalette.page
        skeleton.over = pictureFrame.backgroundColor
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        let h: CGFloat = folded ? 0 : Self.pictureHeight
        pictureFrame.frame = CGRect(x: 0, y: 0, width: w, height: h)
        // The page's chart (or its top) fitted whole into the card, centred on the page's colour.
        if let image = picture.image, image.size.width > 0, image.size.height > 0 {
            let inset: CGFloat = 8
            let scale = min((w - 2 * inset) / image.size.width, (h - 2 * inset) / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            picture.frame = CGRect(x: (w - size.width) / 2, y: (h - size.height) / 2, width: size.width, height: size.height)
        } else {
            picture.frame = CGRect(x: 0, y: 0, width: w, height: h)
        }
        skeleton.frame = CGRect(x: 0, y: 0, width: w, height: h)
        pinBadge.frame = CGRect(x: w - 30, y: 8, width: 22, height: 22)
        pinBadge.layer.cornerRadius = 11
        rule.frame = CGRect(x: 0, y: h, width: w, height: HQShape.pixel(traitCollection.displayScale))
        let g: CGFloat = 18
        let lineH = nameLabel.font?.lineHeight ?? 20
        glyph.frame = CGRect(x: Self.padH, y: h + Self.padV + (lineH - g) / 2, width: g, height: g)
        let textX = glyph.frame.maxX + 8
        let hintH = ceil(hintLabel.font?.lineHeight ?? 16)
        let open: CGFloat = 22
        let textW = w - textX - Self.padH - open - 6
        nameLabel.frame = CGRect(x: textX, y: h + Self.padV, width: textW, height: ceil(lineH))
        hintLabel.frame = CGRect(x: textX, y: nameLabel.frame.maxY + 2, width: textW, height: hintH)
        openGlyph.frame = CGRect(x: w - Self.padH - open, y: h + (bounds.height - h - open) / 2, width: open, height: open)
    }

    /// The picture's top-left pixel: the page's background.
    private static func cornerColor(_ image: UIImage) -> UIColor? {
        guard let cg = image.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 1 - CGFloat(cg.height), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        guard px[3] > 200 else { return nil }
        return UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    }

    /// [mac] The Mac's accessibility press does not send a plain control's touch-up: "Opens the page" opened nothing.
    override func accessibilityActivate() -> Bool { tapped(); return true }

    @objc private func tapped() {
        if let ref { onOpen?(ref) }
    }
}
