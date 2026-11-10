import UIKit

// One photo in a bubble or a reply (docs/spec/1x-attachments.md §7.3, §7.4, §7.7): its exact frame from the layout,
// a Fill 3 placeholder (an indicator only after 0.6 s), the picture decoded off the main thread, the retry tile when it
// can't load, "Photo too large to load", the upload ring while your send uploads, and the generated image's
// "Rendering image" shimmer. Loads start when the tile is configured and stop when it is reused or leaves the window
// (the download itself stops once no tile or viewer waits for it: `MediaLoader` counts its waiters, spec §8.2); a
// tile that left mid-load starts again when it comes back.

/// Taps and the learnt size go up to the cell.
@MainActor protocol MediaTileHost: AnyObject {
    func tileTapped(_ tile: MediaTileView)
    func tileLearnedSize(_ tile: MediaTileView, width: Int, height: Int)
    /// The gateway answered that it has no such file, or keeps it private: a reply's picture becomes a file row.
    func tileUnavailable(_ tile: MediaTileView, error: MediaLoadError)
}

final class MediaTileView: UIView {
    enum Phase: Equatable { case idle, loading, loaded, failed, tooLarge, rendering }

    weak var host: MediaTileHost?
    private(set) var item: MediaItem?
    private(set) var phase: Phase = .idle

    let imageView = MirroredImageView()
    /// Behind a fitted photo: the same picture filled and blurred, so the sides aren't bare (Telegram's look).
    private let backdrop = UIImageView()
    private let backdropBlur = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    /// Show the whole photo (aspect fit) on its blur instead of filling the frame.
    private var fits = false
    /// A stack's card: `fits` follows the photo's own shape (its pixel size, else the decoded picture's): filled when it
    /// is near the card's, whole on its blur when it is not (a screenshot is never cut down to a card's shape).
    private var autoFit = false
    /// The size the picture was last asked for at (`maxPixel`).
    private var requestedPixel = 0
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let failure = PhotoRetryTile()
    private let scrim = UIView()
    private let ring = ProgressRingView()
    private let shimmer = CAGradientLayer()
    private let glyph = UIImageView()
    private var loadTask: Task<Void, Never>?
    private var spinnerWork: DispatchWorkItem?
    private var progressToken: TransferProgressCenter.Token?
    private var itemObservation: AttachmentCenter.Observation?
    private var retriedThisAppearance = false
    /// The load stopped because the tile left the window (scrolled away, a full-screen viewer over the chat).
    private var suspended = false
    /// A load (or the sharper copy of a smaller cached one) is under way.
    private var loadInFlight = false
    private var foregroundObserver: NSObjectProtocol?
    /// [perf] A card deep in a photo stack, out of sight: its photo waits until the card nears the top (16 photos in one
    /// message no longer fetch and decode 16 pictures for the three you can see). Cleared → the load starts.
    var deferred = false {
        didSet {
            guard oldValue != deferred, !deferred, needsStart else { return }
            start()
        }
    }
    /// A configure that `deferred` held back.
    private var needsStart = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = ChatPalette.fill3
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.accessibilityIgnoresInvertColors = true
        backdrop.contentMode = .scaleAspectFill
        backdrop.clipsToBounds = true
        backdrop.accessibilityIgnoresInvertColors = true
        backdrop.isHidden = true
        backdropBlur.isUserInteractionEnabled = false
        backdropBlur.isHidden = true
        addSubview(backdrop)
        addSubview(backdropBlur)
        addSubview(imageView)
        imageView.onImage = { [weak self] image in
            guard let self else { return }
            if self.autoFit, let image { self.setFits(Self.differs(image.size, self.bounds.size)) }
            self.updateBackdrop(image)
        }
        glyph.contentMode = .center
        glyph.tintColor = ChatPalette.label3
        glyph.image = UIImage(systemName: "photo", withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .regular))
        glyph.isHidden = true
        addSubview(glyph)
        spinner.hidesWhenStopped = true
        addSubview(spinner)
        failure.isHidden = true
        failure.isUserInteractionEnabled = false
        addSubview(failure)
        scrim.backgroundColor = UIColor(white: 0, alpha: 0.3)
        scrim.isHidden = true
        scrim.isUserInteractionEnabled = false
        addSubview(scrim)
        ring.isHidden = true
        addSubview(ring)
        isAccessibilityElement = true
        accessibilityTraits = [.image, .button]
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                                                                    queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryAutomatically() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        loadTask?.cancel()
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        backdrop.frame = bounds
        backdropBlur.frame = bounds
        glyph.frame = bounds
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        failure.frame = bounds
        scrim.frame = bounds
        ring.frame = CGRect(x: bounds.midX - 12, y: bounds.midY - 12, width: 24, height: 24)
        shimmer.frame = bounds
    }

    /// The pixel size to decode at: the tile's points × screen scale.
    private var maxPixel: Int {
        let scale = window?.windowScene?.screen.scale ?? traitCollection.displayScale
        return Int(ceil(max(bounds.width, bounds.height) * max(2, scale)))
    }

    func configure(_ item: MediaItem, frame: CGRect, fits: Bool = false, autoFit: Bool = false) {
        let same = self.item?.attachment.source == item.attachment.source && self.item?.rendering == item.rendering
        self.frame = frame
        self.autoFit = autoFit
        var fits = fits
        if autoFit {
            if let w = item.attachment.pixelWidth, let h = item.attachment.pixelHeight, w > 0, h > 0 {
                fits = Self.differs(CGSize(width: w, height: h), frame.size)
            } else if same, let image = imageView.image {
                fits = Self.differs(image.size, frame.size)
            } else {
                fits = self.fits
            }
        }
        setFits(fits)
        self.item = item
        accessibilityLabel = item.label
        accessibilityHint = item.rendering ? nil : "Opens the photo"
        layoutIfNeeded()
        observeUpload(item)
        // A card grown past what the picture was decoded for (a reply picture's shape learnt): decode it again, the
        // smaller copy showing meanwhile.
        let sharp = phase != .loaded || MediaMemoryCache.bucket(maxPixel) <= MediaMemoryCache.bucket(requestedPixel)
        if same && !suspended && sharp && (phase == .loaded || phase == .loading || phase == .rendering) { return }
        if deferred {
            if !same {
                // Another photo now: nothing of the last one's shows or loads (a copy already in memory may show).
                loadTask?.cancel()
                loadTask = nil
                loadInFlight = false
                spinnerWork?.cancel()
                spinner.stopAnimating()
                failure.isHidden = true
                imageView.image = item.context.flatMap { MediaLoader.shared.cachedImage(item.attachment, context: $0, maxPixel: 256) }
                phase = .idle
            }
            needsStart = true
            return
        }
        start()
    }

    func prepareForReuse() {
        needsStart = false
        deferred = false
        loadTask?.cancel()
        loadTask = nil
        loadInFlight = false
        suspended = false
        spinnerWork?.cancel()
        progressToken = nil
        itemObservation = nil
        item = nil
        phase = .idle
        imageView.image = nil
        imageView.alpha = 1
        stopShimmer()
    }

    private func setFits(_ fits: Bool) {
        guard self.fits != fits else { return }
        self.fits = fits
        imageView.contentMode = fits ? .scaleAspectFit : .scaleAspectFill
        updateBackdrop(imageView.image)
    }

    /// A photo of `size` would lose more than an eighth of itself filling `frame`.
    static func differs(_ size: CGSize, _ frame: CGSize) -> Bool {
        guard size.width > 0, size.height > 0, frame.width > 0, frame.height > 0 else { return false }
        let a = size.width / size.height, b = frame.width / frame.height
        return max(a / b, b / a) > 1.14
    }

    private func updateBackdrop(_ image: UIImage?) {
        let show = fits && image != nil
        backdrop.image = show ? image : nil
        backdrop.isHidden = !show
        backdropBlur.isHidden = !show
    }

    // MARK: Loading

    private func start() {
        needsStart = false
        loadTask?.cancel()
        loadInFlight = false
        suspended = false
        spinnerWork?.cancel()
        spinner.stopAnimating()
        failure.isHidden = true
        glyph.isHidden = true
        stopShimmer()
        retriedThisAppearance = false
        guard let item else { return }
        // A retry starts from the photo's own words (the failure tile's "Couldn't load …" stays only while it shows).
        accessibilityLabel = item.label
        if item.rendering {
            phase = .rendering
            imageView.image = nil
            glyph.isHidden = false
            startShimmer()
            return
        }
        if case .tooLarge = item.attachment.source {
            showTooLarge()
            return
        }
        guard let context = item.context else { showFailure(); return }
        requestedPixel = maxPixel
        if let cached = MediaLoader.shared.cachedImage(item.attachment, context: context, maxPixel: maxPixel) {
            imageView.image = cached
            phase = .loaded
            // A smaller cached copy shows at once; the display size follows without a placeholder.
            if MediaMemoryCache.shared.exact(MediaLoader.shared.key(item.attachment, context) ?? "", bucket: MediaMemoryCache.bucket(maxPixel)) != nil {
                return
            }
        } else {
            imageView.image = nil
            phase = .loading
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.phase == .loading else { return }
                self.spinner.startAnimating()
            }
            spinnerWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
        let pixel = maxPixel
        let started = CACurrentMediaTime()
        let fade = item.generated != nil
        loadInFlight = true
        loadTask = Task { [weak self] in
            defer { if !Task.isCancelled { self?.loadInFlight = false } }
            do {
                let loaded = try await MediaLoader.shared.image(item.attachment, context: context, maxPixel: pixel)
                guard let self, !Task.isCancelled, self.item?.attachment.source == item.attachment.source else { return }
                self.spinnerWork?.cancel()
                self.spinner.stopAnimating()
                let hadImage = self.imageView.image != nil
                self.imageView.image = loaded.image
                self.phase = .loaded
                if fade && !hadImage && CACurrentMediaTime() - started > 0.1 && !HQMotion.reduced {
                    self.imageView.alpha = 0
                    UIView.animate(withDuration: 0.2) { self.imageView.alpha = 1 }
                }
                if item.attachment.pixelWidth == nil || item.attachment.pixelHeight == nil {
                    self.host?.tileLearnedSize(self, width: loaded.pixelWidth, height: loaded.pixelHeight)
                }
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled, self.item?.attachment.source == item.attachment.source else { return }
                self.spinnerWork?.cancel()
                self.spinner.stopAnimating()
                let mapped = error as? MediaLoadError
                if mapped == .tooLarge { self.showTooLarge() } else if self.imageView.image == nil { self.showFailure() }
                if let mapped, mapped == .notFound || mapped == .forbidden, item.attachment.gatewayPath != nil, item.index < 0, item.generated == nil {
                    self.host?.tileUnavailable(self, error: mapped)
                }
            }
        }
    }

    private func showFailure() {
        phase = .failed
        imageView.image = nil
        failure.isHidden = false
        let name = item?.attachment.name ?? "Photo"
        if opensAsLink {
            // A generated image that won't load offers itself as a link (spec §7.7); it still retries on its own.
            failure.configure(.openLink(name: name), height: bounds.height)
            accessibilityLabel = "Couldn’t load \(name). \(DeviceWord.Tap) to open."
        } else {
            failure.configure(.retry(name: name, generated: false), height: bounds.height)
            accessibilityLabel = "Couldn’t load \(name). \(DeviceWord.Tap) to try again."
        }
    }

    /// A settled generated image: when it can't load, a tap opens it (Safari for a URL, the file preview for a path).
    var opensAsLink: Bool { item?.generated != nil && item?.rendering == false }

    private func showTooLarge() {
        phase = .tooLarge
        imageView.image = nil
        failure.isHidden = false
        failure.configure(.tooLarge(name: item?.attachment.name ?? "Photo"), height: bounds.height)
        accessibilityLabel = "Photo too large to load. \(DeviceWord.Tap) to open."
    }

    /// Automatic retry, once per trigger (spec §7.4): back on screen, back in the foreground.
    func retryAutomatically() {
        guard phase == .failed, window != nil, !retriedThisAppearance else { return }
        retriedThisAppearance = true
        start()
        retriedThisAppearance = true
    }

    /// The gateway link came back (spec §7.4's third trigger). Its own trigger, so it ignores the
    /// once-per-appearance flag a foreground retry may already have spent while the network was still coming up.
    func retryAfterReconnect() {
        guard phase == .failed, window != nil else { return }
        start()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            retriedThisAppearance = false
            // Off screen: stop waiting, so a download nobody else wants is cancelled and the photos on screen go first.
            if loadInFlight {
                loadTask?.cancel()
                loadTask = nil
                loadInFlight = false
                spinnerWork?.cancel()
                spinner.stopAnimating()
                suspended = true
            }
        } else if suspended {
            start()
        } else {
            retryAutomatically()
        }
    }

    @objc private func tapped() {
        switch phase {
        case .failed where !opensAsLink: start()
        default: host?.tileTapped(self)
        }
    }

    // MARK: Upload ring (your sending message)

    private func observeUpload(_ item: MediaItem) {
        guard case .local(let draftId) = item.attachment.source, let context = item.context,
              let center = AttachmentCenter.existing(context.accountId) else {
            progressToken = nil
            itemObservation = nil
            showRing(nil)
            return
        }
        let update: () -> Void = { [weak self, weak center] in
            guard let self, let center else { return }
            switch center.items[draftId]?.upload {
            case .uploading?, .waiting?, .preparing?:
                self.showRing(TransferProgressCenter.shared.fraction(draftId) ?? 0)
            default:
                self.showRing(nil)
            }
        }
        itemObservation = center.observeItems { id in if id == draftId { update() } }
        progressToken = TransferProgressCenter.shared.observe(draftId) { [weak self] fraction in
            guard let self, fraction != nil else { update(); return }
            self.showRing(fraction)
        }
        update()
    }

    private func showRing(_ fraction: Double?) {
        scrim.isHidden = fraction == nil
        ring.isHidden = fraction == nil
        if let fraction { ring.progress = fraction }
        accessibilityValue = fraction.map { "Uploading, \(Int($0 * 100)) percent" }
    }

    // MARK: Shimmer (a generated image still rendering)

    private func startShimmer() {
        accessibilityLabel = "Rendering image"
        guard !HQMotion.reduced else { return }
        let base = ChatPalette.fill3.resolvedColor(with: traitCollection)
        let light = ChatPalette.fill1.resolvedColor(with: traitCollection)
        shimmer.colors = [base.cgColor, light.cgColor, base.cgColor]
        shimmer.locations = [0, 0.5, 1]
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.frame = bounds
        layer.insertSublayer(shimmer, at: 0)
        let move = CABasicAnimation(keyPath: "locations")   // motion-ok: Reduce Motion returned in the guard above
        move.fromValue = [-1, -0.5, 0]
        move.toValue = [1, 1.5, 2]
        move.duration = 1.6
        move.repeatCount = .infinity
        shimmer.add(move, forKey: "shimmer")
    }

    private func stopShimmer() {
        shimmer.removeAllAnimations()
        shimmer.removeFromSuperlayer()
    }
}

/// The determinate ring on an uploading photo: 24 pt, white, 2.5 pt (spec §6.2).
final class ProgressRingView: UIView {
    private let track = CAShapeLayer()
    private let bar = CAShapeLayer()

    var progress: Double = 0 { didSet { bar.strokeEnd = CGFloat(min(1, max(0.02, progress))) } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for l in [track, bar] {
            l.fillColor = nil
            l.lineWidth = 2.5
            l.lineCap = .round
            layer.addSublayer(l)
        }
        track.strokeColor = UIColor(white: 1, alpha: 0.35).cgColor
        bar.strokeColor = UIColor.white.cgColor
        bar.strokeEnd = 0.02
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let path = UIBezierPath(arcCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: bounds.width / 2 - 1.25,
                                startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true).cgPath
        track.frame = bounds
        bar.frame = bounds
        track.path = path
        bar.path = path
    }
}

/// The tile an image shows when it can't (spec §7.4; R:src/fe-convo-r2-ui.tsx:14-40): a dashed separator border,
/// radius 14, 5 % label fill, the glyph, the words and the name; below 120 pt only the glyph.
final class PhotoRetryTile: UIView {
    enum Kind: Equatable {
        case retry(name: String, generated: Bool)
        case tooLarge(name: String)
        case openLink(name: String)
    }

    private let border = CAShapeLayer()
    private let glyph = UIImageView()
    private let title = UILabel()
    private let action = UILabel()
    private let nameLabel = UILabel()
    private var compact = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = ChatPalette.label.withAlphaComponent(0.05)
        border.fillColor = nil
        border.lineWidth = 1
        border.lineDashPattern = [4, 3]
        layer.addSublayer(border)
        glyph.contentMode = .center
        glyph.tintColor = ChatPalette.label2
        addSubview(glyph)
        title.font = HQFont.scaled(14, weight: .medium, like: .subheadline, cap: 22)
        title.adjustsFontForContentSizeCategory = true   // [a11y] follows a live text-size change
        title.textColor = ChatPalette.label
        title.textAlignment = .center
        action.font = HQFont.scaled(13, like: .footnote, cap: 20)
        action.adjustsFontForContentSizeCategory = true   // [a11y] follows a live text-size change
        action.textColor = ChatPalette.tintText
        action.textAlignment = .center
        action.lineBreakMode = .byTruncatingMiddle
        nameLabel.font = HQFont.scaled(12, like: .caption1, cap: 20)
        nameLabel.adjustsFontForContentSizeCategory = true   // [a11y] follows a live text-size change
        nameLabel.textColor = ChatPalette.label2   // [a11y] a name to read: secondary ink, not the 36 % tertiary
        nameLabel.textAlignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        for l in [title, action, nameLabel] { addSubview(l) }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (view: PhotoRetryTile, _) in view.recolor() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The titles are state captions inside the frame, in sentence case like "Tap to retry" under them (and the tray's
    /// "Couldn’t upload"), not alert titles: those ("Couldn’t Attach", "Couldn’t Open File") stay Title Case.
    func configure(_ kind: Kind, height: CGFloat) {
        compact = height < 120
        switch kind {
        case .retry(let name, let generated):
            glyph.image = UIImage(systemName: "arrow.clockwise", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular))
            title.text = generated ? "Couldn’t load image" : "Couldn’t load photo"
            action.text = "\(DeviceWord.Tap) to try again"
            nameLabel.text = name
        case .tooLarge(let name):
            glyph.image = UIImage(systemName: "photo", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular))
            title.text = "Photo too large to load"
            action.text = "\(DeviceWord.Tap) to open"
            nameLabel.text = name
        case .openLink(let name):
            glyph.image = UIImage(systemName: "photo", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular))
            title.text = "Couldn’t load image"
            action.text = "Open image: \(name)"
            nameLabel.text = nil
        }
        for l in [title, action, nameLabel] { l.isHidden = compact }
        recolor()
        setNeedsLayout()
    }

    private func recolor() {
        border.strokeColor = ChatPalette.separator.resolvedColor(with: traitCollection).cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = HQShape.radius(14, .tile)
        layer.cornerCurve = .continuous
        border.frame = bounds
        border.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerRadius: HQShape.radius(14, .tile)).cgPath
        if compact {
            glyph.frame = bounds
            return
        }
        let lineTitle = ceil(title.font.lineHeight), lineAction = ceil(action.font.lineHeight)
        let lineName = nameLabel.text == nil ? 0 : ceil(nameLabel.font.lineHeight)
        let total: CGFloat = 26 + 8 + lineTitle + 2 + lineAction + (lineName > 0 ? 4 + lineName : 0)
        var y = (bounds.height - total) / 2
        glyph.frame = CGRect(x: 0, y: y, width: bounds.width, height: 26)
        y += 26 + 8
        title.frame = CGRect(x: 8, y: y, width: bounds.width - 16, height: lineTitle)
        y += lineTitle + 2
        action.frame = CGRect(x: 8, y: y, width: bounds.width - 16, height: lineAction)
        y += lineAction + 4
        nameLabel.frame = CGRect(x: 8, y: y, width: bounds.width - 16, height: lineName)
    }
}

/// An image view that says when its picture changes (the tile's blurred backdrop follows it).
final class MirroredImageView: UIImageView {
    var onImage: ((UIImage?) -> Void)?
    override var image: UIImage? {
        didSet { onImage?(image) }
    }
}
