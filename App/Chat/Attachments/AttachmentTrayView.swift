import UIKit

// The attachment tray above the composer row (docs/spec/1x-attachments.md §6.2): a horizontal row of 64 pt tiles —
// photos as square thumbnails, files as cards with their kind, name and "PDF · 2.4 MB" — each with its upload state
// (preparing, waiting, uploading ring, failed) and a remove button. [glass-phone] The band is a native Liquid Glass
// panel (owner 2026-10-30: "more Liquid Glass"), a rounded card on the composer row's edges, 10 pt around the tiles.
// Every tile stays fully opaque (its card is the page colour, under the photo, the icon and the words): the owner saw
// the transcript "read straight through the tile and its name" on the web's see-through tray, and only the glass
// between the tiles may show it now. The Desktop Look has no glass: there the band is today's opaque page-colour strip
// (drawn here, so ThemeChrome leaves the panel alone).

@MainActor protocol AttachmentTrayDelegate: AnyObject {
    func trayRemove(_ id: String)
    func trayRetry(_ id: String)
    func trayOpen(_ id: String, from view: UIView)
}

final class AttachmentTrayView: UIView {
    static let tileHeight: CGFloat = 64
    /// Room above the tiles for the remove buttons: the ✕ sits 6 pt outside the tile's corner and its 44 pt target
    /// reaches 17 pt above the tile, all of it inside the tray (which clips, so it stays opaque over the transcript).
    static let topRoom: CGFloat = 17
    /// Space between the band and the composer row.
    static let gapBelow: CGFloat = 8
    /// [glass-phone] The glass card's padding around the tiles (iOS look); its corners are the file tile's 14 pt plus
    /// this, concentric with the tiles.
    static let glassPad: CGFloat = 10
    static var glassRadius: CGFloat { 14 + glassPad }
    /// The tray's height: the glass card's padding sits under the tiles in the iOS look; the look's strip has none.
    @MainActor static var height: CGFloat { topRoom + tileHeight + (ComposerView.oneBox ? 0 : glassPad) + gapBelow }

    weak var delegate: AttachmentTrayDelegate?
    /// Where the first tile starts (the field's leading edge).
    var leadingInset: CGFloat = 26 { didSet { if leadingInset != oldValue { setNeedsLayout() } } }

    /// The look changed (the tray's height with it): the owner sets the composer's room for it again.
    var onLookChange: (() -> Void)?

    /// [glass-phone] The band: a glass card off the Desktop Look, the page-colour strip in it (`applyLook`).
    private let panel = UIVisualEffectView()
    private let scroll = UIScrollView()
    private var tiles: [String: TrayTileView] = [:]
    private var order: [String] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        DesktopLayout.keepOwnLook(panel)
        addSubview(panel)
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        // A tile scrolled past the card's side is cut at the card's rounded edge, never drawn over the transcript.
        scroll.clipsToBounds = true
        scroll.accessibilityIdentifier = "composer.tray"
        panel.contentView.addSubview(scroll)
        clipsToBounds = true
        applyLook()
        registerForTraitChanges([ThemeGenerationTrait.self]) { (tray: AttachmentTrayView, _) in
            let was = tray.desktop
            tray.applyLook()
            if was != tray.desktop { tray.onLookChange?() }
        }
    }

    private var desktop = false

    /// Glass (untinted, not interactive: the tiles are the controls), or the Desktop Look's opaque strip.
    private func applyLook() {
        desktop = ComposerView.oneBox   // [mac] the opaque strip over the Mac's box, not glass
        if desktop {
            if panel.effect != nil { panel.effect = nil }
            panel.backgroundColor = ChatPalette.page
            panel.cornerConfiguration = .corners(radius: .fixed(0))
            scroll.cornerConfiguration = .corners(radius: .fixed(0))
        } else {
            if !(panel.effect is UIGlassEffect) { panel.effect = UIGlassEffect(style: .regular) }
            panel.backgroundColor = nil
            panel.cornerConfiguration = .corners(radius: .fixed(Self.glassRadius))
            scroll.cornerConfiguration = .corners(radius: .fixed(Self.glassRadius))
        }
        setNeedsLayout()
    }

    /// The band's frame in the tray (tests).
    var panelFrame: CGRect { panel.frame }
    /// Whether the band is glass now (tests).
    var isGlass: Bool { panel.effect is UIGlassEffect }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var isEmpty: Bool { order.isEmpty }

    /// Shows `attachments` in tray order (insertions and removals glide with the system spring).
    func update(_ attachments: [DraftAttachment], staging: AttachmentStaging?, animated: Bool) {
        let ids = attachments.map(\.id)
        let removed = order.filter { !ids.contains($0) }
        for id in removed {
            guard let tile = tiles.removeValue(forKey: id) else { continue }
            if animated && !HQMotion.reduced {
                UIView.animate(withDuration: 0.25, animations: { tile.alpha = 0; tile.transform = CGAffineTransform(scaleX: 0.6, y: 0.6) },
                               completion: { _ in tile.removeFromSuperview() })
            } else {
                tile.removeFromSuperview()
            }
        }
        var inserted: [TrayTileView] = []
        for a in attachments {
            if let tile = tiles[a.id] {
                tile.update(a, staging: staging)
            } else {
                let tile = TrayTileView()
                tile.delegate = delegate
                tile.update(a, staging: staging)
                tiles[a.id] = tile
                scroll.addSubview(tile)
                inserted.append(tile)
            }
        }
        order = ids
        for (i, id) in order.enumerated() { tiles[id]?.index = i }
        if animated && !HQMotion.reduced {
            layoutTiles(placing: inserted)
            for t in inserted { t.alpha = 0; t.transform = CGAffineTransform(scaleX: 0.6, y: 0.6) }
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                for t in inserted { t.alpha = 1; t.transform = .identity }
                self.layoutTiles(placing: [])
            }
            if let last = inserted.last {
                scroll.scrollRectToVisible(last.frame.insetBy(dx: -16, dy: 0), animated: true)
            }
        } else {
            layoutTiles(placing: [])
        }
    }

    func tile(for id: String) -> UIView? { tiles[id] }

    /// The tiles on screen, in window coordinates (nil when none): where a send with attachments lifts from.
    func liftBox() -> CGRect? {
        guard window != nil, !order.isEmpty, bounds.height > 0 else { return nil }
        let visible = panel.convert(panel.bounds, to: nil)
        var box = CGRect.null
        for id in order {
            guard let tile = tiles[id] else { continue }
            let frame = scroll.convert(tile.frame, to: nil).intersection(visible)
            if !frame.isNull, frame.width > 0, frame.height > 0 { box = box.union(frame) }
        }
        return box.isNull ? nil : box
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if desktop {
            panel.frame = bounds
        } else {
            // On the composer row's edges (26 pt resting, 8 pt over the keys), as the queue card above it.
            let side = (superview as? ComposerView)?.currentSideInset ?? ChatMetrics.composerSideDown
            panel.frame = CGRect(x: side, y: Self.topRoom - Self.glassPad, width: max(0, bounds.width - 2 * side),
                                 height: Self.tileHeight + 2 * Self.glassPad)
        }
        scroll.frame = panel.bounds
        layoutTiles(placing: [])
    }

    private func layoutTiles(placing: [TrayTileView]) {
        // The first tile lines up with the field while the tiles fit beside it; when they don't, the tray starts at the
        // screen's side margin (where ☰ sits) and only scrolls once even that is too narrow (verify round 1: a scrolled
        // tray left its first tile at 67 pt, lined up with nothing, or cut at the screen's edge at accessibility sizes).
        // [glass-phone] Inside the glass card the margin is the card's padding, and the field's edge is measured from
        // the card's.
        var margin = desktop ? ChatMetrics.composerSideDown : Self.glassPad
        var lineUp = leadingInset - panel.frame.minX
        /// The room kept past the last tile (the scroll to the newest one must not push the first one off).
        var trailing = margin
        // [Mac UI check 2026-11-13] V35: over the look's one box the tiles start at the box's own leading edge; lined up
        // with the field (after ☰ and +) they sat off the box's edge, belonging to neither. The box's edge is measured in
        // the panel's own space, and the first tile's hairline sits just inside it, never on the scroll's clipped edge.
        if desktop, let composer = superview as? ComposerView {
            let edge = composer.convert(CGPoint(x: composer.currentSideInset - composer.boxOutset, y: 0), to: panel).x
            lineUp = max(2, edge.rounded() + 1)
            margin = lineUp
            trailing = max(trailing, lineUp)
        }
        let width = panel.bounds.width
        let tilesWidth = order.compactMap { tiles[$0]?.preferredWidth }.reduce(0) { $0 + $1 + 8 } - 8
        var x = max(lineUp, margin)
        if x > margin, x + tilesWidth + margin > width { x = margin }
        let y = desktop ? Self.topRoom : Self.glassPad
        for id in order {
            guard let tile = tiles[id] else { continue }
            let w = tile.preferredWidth
            let frame = CGRect(x: x, y: y, width: w, height: Self.tileHeight)
            if tile.transform == .identity || placing.contains(where: { $0 === tile }) {
                let t = tile.transform
                tile.transform = .identity
                tile.frame = frame
                tile.transform = t
            }
            x += w + 8
        }
        // Integration: the end keeps the screen's side margin, not the field's leading edge (with ☰ and + before the
        // field that was 118 pt of empty room, and the scroll to the newest tile cut the first one at the left edge).
        scroll.contentSize = CGSize(width: x - 8 + trailing, height: panel.bounds.height)
        // All of it fits: nothing is scrolled, so the first tile is never cut at the strip's leading edge.
        if scroll.contentSize.width <= scroll.bounds.width + 0.5, scroll.contentOffset.x != 0 { scroll.contentOffset.x = 0 }
    }
}

/// One tray tile.
final class TrayTileView: UIView {
    weak var delegate: AttachmentTrayDelegate?
    var index = 0 { didSet { identify() } }

    private(set) var attachment: DraftAttachment?
    private let card = UIView()
    private let thumb = UIImageView()
    private let iconBox = UIView()
    private let icon = UIImageView()
    private let name = UILabel()
    private let detail = UILabel()
    private let scrim = UIView()
    private let ring = ProgressRingView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let failedBadge = UIImageView()
    private let removeButton = UIButton(type: .custom)
    /// The ✕ sits on the page colour: an opaque disc behind the symbol, never the photo showing through it.
    private let removeDisc = UIView()
    private let tapControl = UIButton(type: .custom)
    private var progressToken: TransferProgressCenter.Token?
    private var thumbTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        card.clipsToBounds = true
        card.backgroundColor = ChatPalette.page
        card.layer.borderWidth = 0.5
        card.layer.cornerCurve = .continuous
        addSubview(card)
        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.backgroundColor = ChatPalette.fill3
        card.addSubview(thumb)
        iconBox.backgroundColor = ChatPalette.fill3
        iconBox.layer.cornerRadius = HQShape.radius(10, .tile)
        iconBox.layer.cornerCurve = .continuous
        card.addSubview(iconBox)
        icon.contentMode = .center
        icon.tintColor = ChatPalette.label2
        iconBox.addSubview(icon)
        name.font = HQFont.scaled(15, weight: .semibold, like: .subheadline, cap: 22)
        name.adjustsFontForContentSizeCategory = true   // [a11y] follows a live text-size change
        name.textColor = ChatPalette.label
        name.lineBreakMode = .byTruncatingMiddle
        card.addSubview(name)
        // Capped as the name is, so the two lines stay inside the 64 pt tile at every text size.
        detail.font = HQFont.scaled(12, like: .caption1, cap: 18)
        detail.adjustsFontForContentSizeCategory = true   // [a11y] follows a live text-size change, as the name does
        detail.textColor = ChatPalette.label2
        card.addSubview(detail)
        scrim.backgroundColor = UIColor(white: 0, alpha: 0.3)
        scrim.isUserInteractionEnabled = false
        card.addSubview(scrim)
        card.addSubview(ring)
        spinner.hidesWhenStopped = true
        card.addSubview(spinner)
        failedBadge.image = UIImage(systemName: "exclamationmark.circle.fill",
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold))
        failedBadge.tintColor = ChatPalette.alertRed
        failedBadge.contentMode = .center
        failedBadge.backgroundColor = .clear
        card.addSubview(failedBadge)
        tapControl.addTarget(self, action: #selector(tapped), for: .touchUpInside)
        addSubview(tapControl)
        let x = UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            .applying(UIImage.SymbolConfiguration(hierarchicalColor: ChatPalette.label2)))
        removeButton.setImage(x, for: .normal)
        removeButton.addTarget(self, action: #selector(removeTapped), for: .touchUpInside)
        removeDisc.backgroundColor = ChatPalette.page
        removeDisc.isUserInteractionEnabled = false
        removeButton.insertSubview(removeDisc, at: 0)
        addSubview(removeButton)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: TrayTileView, _) in view.recolor() }
        // The two lines are placed from their fonts' heights: a live text-size change places them again.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: TrayTileView, _) in view.setNeedsLayout() }
        recolor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit { thumbTask?.cancel() }

    private func recolor() {
        card.layer.borderColor = ChatPalette.separator.resolvedColor(with: traitCollection).cgColor
    }

    var preferredWidth: CGFloat {
        guard let a = attachment, a.kind != .image else { return AttachmentTrayView.tileHeight }
        let nameW = ceil((a.name as NSString).size(withAttributes: [.font: name.font!]).width)
        let detailW = ceil((detailText as NSString).size(withAttributes: [.font: detail.font!]).width)
        return min(240, max(160, 12 + 40 + 10 + max(nameW, detailW) + 12))
    }

    private var detailText: String {
        guard let a = attachment else { return "" }
        if a.kind == .link { return "Link" }
        return MediaKinds.detail(name: a.name, bytes: a.byteSize > 0 ? a.byteSize : nil)
    }

    func update(_ a: DraftAttachment, staging: AttachmentStaging?) {
        let firstTime = attachment?.id != a.id
        attachment = a
        let isPhoto = a.kind == .image
        card.layer.cornerRadius = isPhoto ? 10 : 14
        thumb.isHidden = !isPhoto
        iconBox.isHidden = isPhoto
        name.isHidden = isPhoto
        detail.isHidden = isPhoto
        if !isPhoto {
            icon.image = UIImage(systemName: a.kind == .link ? "link" : MediaKinds.glyph(MediaKinds.kind(ofName: a.name)),
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium))
            name.text = a.kind == .link ? LinkText.display(a.name) : a.name
            detail.text = detailText
        }
        if isPhoto, firstTime || thumb.image == nil { loadThumb(a, staging: staging) }
        if firstTime {
            progressToken = TransferProgressCenter.shared.observe(a.id) { [weak self] fraction in
                guard let self, case .uploading? = self.attachment?.upload else { return }
                self.ring.progress = fraction ?? 0
                self.applyAccessibility()
            }
        }
        applyState()
        identify()
        setNeedsLayout()
    }

    private func loadThumb(_ a: DraftAttachment, staging: AttachmentStaging?) {
        if let hit = MediaMemoryCache.shared.image("l|" + a.id, bucket: 256) { thumb.image = hit; return }
        guard !a.isPreparing, let staging else { return }
        let scale = window?.windowScene?.screen.scale ?? 3
        thumbTask?.cancel()
        thumbTask = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                AttachmentImporter.thumbnail(a, staging: staging, scale: scale).map { UIImage(cgImage: $0) }
            }.value
            guard let self, let image, !Task.isCancelled, self.attachment?.id == a.id else { return }
            MediaMemoryCache.shared.set(image, key: "l|" + a.id, bucket: 256)
            self.thumb.image = image
        }
    }

    private func applyState() {
        guard let a = attachment else { return }
        var showRing = false, showScrim = false, showSpinner = false, failed = false
        var thumbAlpha: CGFloat = 1
        switch a.upload {
        case .preparing(let fraction):
            if let fraction { showRing = true; ring.progress = fraction } else { showSpinner = true }
            thumb.backgroundColor = ChatPalette.fill3
        case .waiting:
            thumbAlpha = 0.6
        case .uploading:
            showRing = true
            showScrim = a.kind == .image
            ring.progress = TransferProgressCenter.shared.fraction(a.id) ?? 0
        case .uploaded:
            break
        case .failed:
            failed = true
        }
        thumb.alpha = thumbAlpha
        iconBox.alpha = thumbAlpha
        scrim.isHidden = !showScrim
        ring.isHidden = !showRing
        // On a file card the ring sits on the icon (no scrim over words); white reads on the photo's scrim only.
        if a.kind != .image && showRing {
            ring.isHidden = true
            showSpinner = true
        }
        if showSpinner { spinner.startAnimating() } else { spinner.stopAnimating() }
        failedBadge.isHidden = !failed
        applyAccessibility()
        tapControl.menu = failed ? failureMenu(a) : nil
        tapControl.showsMenuAsPrimaryAction = failed
    }

    private func failureMenu(_ a: DraftAttachment) -> UIMenu {
        let id = a.id
        let remove = UIAction(title: "Remove", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.delegate?.trayRemove(id)
        }
        // A final refusal (too big, refused) would only fail again: the menu offers Remove alone.
        guard a.offersRetry else { return UIMenu(title: a.failure?.reason ?? "Couldn’t upload", children: [remove]) }
        return UIMenu(title: a.failure?.reason ?? "Couldn’t upload", children: [
            UIAction(title: "Try Again", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.delegate?.trayRetry(id) },
            remove,
        ])
    }

    private func applyAccessibility() {
        guard let a = attachment else { return }
        tapControl.accessibilityLabel = (a.kind == .image ? "Photo, " : (a.kind == .link ? "Link, " : "File, ")) + a.name
        switch a.upload {
        case .preparing: tapControl.accessibilityValue = "Preparing"
        case .waiting: tapControl.accessibilityValue = "Waiting for connection"
        case .uploading: tapControl.accessibilityValue = "Uploading, \(Int((TransferProgressCenter.shared.fraction(a.id) ?? 0) * 100)) percent"
        case .uploaded: tapControl.accessibilityValue = nil
        case .failed: tapControl.accessibilityValue = "Couldn’t upload"
        }
        removeButton.accessibilityLabel = a.kind == .link ? "Remove link" : "Remove \(a.name)"
    }

    private func identify() {
        tapControl.accessibilityIdentifier = "composer.tray.tile.\(index)"
        removeButton.accessibilityIdentifier = "composer.tray.remove.\(index)"
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        card.frame = bounds
        thumb.frame = card.bounds
        scrim.frame = card.bounds
        iconBox.frame = CGRect(x: 12, y: (bounds.height - 40) / 2, width: 40, height: 40)
        icon.frame = iconBox.bounds
        let textX: CGFloat = 12 + 40 + 10
        let nameH = ceil(name.font.lineHeight), detailH = ceil(detail.font.lineHeight)
        let top = (bounds.height - nameH - 2 - detailH) / 2
        name.frame = CGRect(x: textX, y: top, width: max(0, bounds.width - textX - 12), height: nameH)
        detail.frame = CGRect(x: textX, y: top + nameH + 2, width: max(0, bounds.width - textX - 12), height: detailH)
        let ringCenter = attachment?.kind != .image ? CGPoint(x: iconBox.frame.midX, y: iconBox.frame.midY) : CGPoint(x: bounds.midX, y: bounds.midY)
        ring.frame = CGRect(x: ringCenter.x - 12, y: ringCenter.y - 12, width: 24, height: 24)
        spinner.center = ringCenter
        failedBadge.frame = attachment?.kind != .image ? iconBox.frame : card.bounds
        tapControl.frame = bounds
        // 22 pt glyph at the top-trailing corner, offset (−6, −6) outward; a 44 pt target.
        // [Mac UI check 2026-11-13] V35: over the Mac's one box the ✕ sits inside the tile's corner (4 pt in), where a
        // pointer finds it; outside the corner it hung over the strip's edge.
        let inside = ComposerView.oneBox
        removeButton.frame = inside ? CGRect(x: bounds.width - 22 - 4 - 11, y: 4 - 11, width: 44, height: 44)
            : CGRect(x: bounds.width - 22 + 6 - 11, y: -6 - 11, width: 44, height: 44)
        removeDisc.frame = CGRect(x: 11, y: 11, width: 22, height: 22)
        removeDisc.layer.cornerRadius = 11
        removeButton.sendSubviewToBack(removeDisc)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.contains(point) || removeButton.frame.contains(point)
    }

    @objc private func tapped() {
        guard let a = attachment, a.failure == nil, !a.isPreparing else { return }
        delegate?.trayOpen(a.id, from: thumb.isHidden ? self : thumb)
    }

    @objc private func removeTapped() {
        guard let a = attachment else { return }
        Haptics.play(.selection)
        delegate?.trayRemove(a.id)
    }
}
