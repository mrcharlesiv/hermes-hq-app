import UIKit

/// What the Screen shows when the gateway has no live screen (docs/spec/3x-screen.md §5.14): why, the bot's newest
/// screenshot (zoomable, updated while the bot works), its caption and age, then the setup card.
final class LatestScreenshotsView: UIView, UIScrollViewDelegate {
    let card = ScreenSetupCard(controlOnly: false)
    private let feed: ScreenshotFeed
    private let client: any GatewayClient
    private let page = UIScrollView()
    private let stack = UIStackView()
    private let heading = UILabel()
    private let detail = UILabel()
    private let frameView = UIView()
    private let zoom = UIScrollView()
    private let picture = UIImageView()
    private let status = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let caption = UILabel()
    private var aspect: NSLayoutConstraint?
    private var loadTask: Task<Void, Never>?
    private var loadedId: String?
    private var loadedAttempt = 0
    private var ageTimer: Timer?
    private var reason = ScreenSession.Fallback.unsupported
    private var blocker: String?
    /// A Hermes Cloud agent: Nous updates its Hermes, and the Mac setup card has nothing to offer there.
    var managed = false

    init(feed: ScreenshotFeed, client: any GatewayClient) {
        self.feed = feed
        self.client = client
        super.init(frame: .zero)
        backgroundColor = HQPalette.groupedPage
        page.translatesAutoresizingMaskIntoConstraints = false
        page.alwaysBounceVertical = true
        page.accessibilityIdentifier = "screenshots.page"
        addSubview(page)
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: leadingAnchor), page.trailingAnchor.constraint(equalTo: trailingAnchor),
            page.topAnchor.constraint(equalTo: topAnchor), page.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: page.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: page.frameLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: page.contentLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: page.contentLayoutGuide.bottomAnchor, constant: -24),
        ])

        heading.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: HQFont.system(ofSize: 20, weight: .semibold))
        heading.accessibilityTraits = .header
        heading.accessibilityIdentifier = "screenshots.heading"
        detail.font = HQFont.preferred(.subheadline)
        detail.textColor = HQPalette.label2
        detail.accessibilityIdentifier = "screenshots.detail"
        caption.font = HQFont.preferred(.footnote)
        caption.textColor = HQPalette.label2
        caption.accessibilityIdentifier = "screenshots.caption"
        status.font = HQFont.preferred(.subheadline)
        status.textColor = HQPalette.label2
        status.textAlignment = .center
        status.accessibilityIdentifier = "screenshots.status"
        for label in [heading, detail, caption, status] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }

        frameView.backgroundColor = .tertiarySystemFill
        frameView.layer.cornerRadius = HQShape.radius(16, .card)
        frameView.layer.cornerCurve = .continuous
        frameView.clipsToBounds = true
        zoom.delegate = self
        zoom.maximumZoomScale = 5
        zoom.minimumZoomScale = 1
        zoom.showsVerticalScrollIndicator = false
        zoom.showsHorizontalScrollIndicator = false
        zoom.bouncesZoom = true
        zoom.translatesAutoresizingMaskIntoConstraints = false
        zoom.isAccessibilityElement = true
        zoom.accessibilityTraits = .image
        zoom.accessibilityIdentifier = "screenshots.picture"
        picture.contentMode = .scaleAspectFit
        picture.translatesAutoresizingMaskIntoConstraints = false
        // The frame's shape comes from the screenshot's proportions alone: a picture's own point size (a 640 × 400
        // capture that arrives inline is 400 pt tall) must never stretch it.
        for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
            picture.setContentCompressionResistancePriority(UILayoutPriority(1), for: axis)
            picture.setContentHuggingPriority(UILayoutPriority(1), for: axis)
        }
        zoom.addSubview(picture)
        frameView.addSubview(zoom)
        let empty = UIStackView(arrangedSubviews: [spinner, status])
        empty.axis = .vertical
        empty.spacing = 10
        empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false
        frameView.addSubview(empty)
        let wide = frameView.heightAnchor.constraint(equalTo: frameView.widthAnchor, multiplier: 10.0 / 16.0)
        wide.priority = .defaultHigh
        aspect = wide
        NSLayoutConstraint.activate([
            zoom.leadingAnchor.constraint(equalTo: frameView.leadingAnchor), zoom.trailingAnchor.constraint(equalTo: frameView.trailingAnchor),
            zoom.topAnchor.constraint(equalTo: frameView.topAnchor), zoom.bottomAnchor.constraint(equalTo: frameView.bottomAnchor),
            picture.leadingAnchor.constraint(equalTo: zoom.contentLayoutGuide.leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: zoom.contentLayoutGuide.trailingAnchor),
            picture.topAnchor.constraint(equalTo: zoom.contentLayoutGuide.topAnchor),
            picture.bottomAnchor.constraint(equalTo: zoom.contentLayoutGuide.bottomAnchor),
            picture.widthAnchor.constraint(equalTo: zoom.frameLayoutGuide.widthAnchor),
            picture.heightAnchor.constraint(equalTo: zoom.frameLayoutGuide.heightAnchor),
            empty.leadingAnchor.constraint(equalTo: frameView.leadingAnchor, constant: 16),
            empty.trailingAnchor.constraint(equalTo: frameView.trailingAnchor, constant: -16),
            empty.topAnchor.constraint(greaterThanOrEqualTo: frameView.topAnchor, constant: 14),
            empty.bottomAnchor.constraint(lessThanOrEqualTo: frameView.bottomAnchor, constant: -14),
            empty.centerYAnchor.constraint(equalTo: frameView.centerYAnchor),
            wide,
        ])
        let twice = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        twice.numberOfTapsRequired = 2
        zoom.addGestureRecognizer(twice)

        for view in [padded(heading, top: 12, bottom: 4), padded(detail, top: 4, bottom: 14), frameView, padded(caption, top: 0, bottom: 4), card] {
            stack.addArrangedSubview(view)
        }
        // The same gap under the picture whether or not it has a caption.
        stack.setCustomSpacing(12, after: frameView)
        stack.setCustomSpacing(12, after: stack.arrangedSubviews[3])
        feed.onChange = { [weak self] in self?.render() }
        feed.onNewShot = { HQAnnounce.say("New screenshot") }
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit {
        loadTask?.cancel()
        ageTimer?.invalidate()
    }

    private func padded(_ label: UILabel, top: CGFloat, bottom: CGFloat) -> UIView {
        let box = UIStackView(arrangedSubviews: [label])
        box.isLayoutMarginsRelativeArrangement = true
        box.directionalLayoutMargins = NSDirectionalEdgeInsets(top: top, leading: 0, bottom: bottom, trailing: 0)
        return box
    }

    func update(reason: ScreenSession.Fallback, blocker: String?) {
        self.reason = reason
        self.blocker = blocker
        render()
    }

    /// On screen and the app active: the poll, the live events and the age clock run only then.
    func setVisible(_ on: Bool) {
        feed.setVisible(on)
        ageTimer?.invalidate()
        ageTimer = nil
        guard on else { return }
        render()
        ageTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderCaption() }
        }
    }

    private func renderCaption() {
        let text = feed.caption()
        caption.text = text
        caption.superview?.isHidden = text.isEmpty
        zoom.accessibilityValue = text
    }

    private func render() {
        let host = feed.hostKind
        let words = ScreenshotRules.heading(reason, name: feed.name, host: host, blocker: blocker.map(ScreenWire.plain), managed: managed)
        heading.text = words.title
        detail.text = words.detail
        card.windows = host == .windows
        card.needsUpdate = reason == .unavailable
        card.isHidden = managed
        renderCaption()
        zoom.accessibilityLabel = "\(feed.name)’s latest screenshot"
        let showsPicture = picture.image != nil && feed.state != .expired && feed.state != .unloadable
        zoom.isHidden = !showsPicture
        status.text = showsPicture ? "" : feed.emptyLine
        status.isHidden = showsPicture
        let waiting = !showsPicture && (feed.state == .searching || feed.state == .loading)
        if waiting { spinner.startAnimating() } else { spinner.stopAnimating() }
        frameView.accessibilityIdentifier = "screenshots.frame.\(feed.state)"
        if feed.state == .expired { setPicture(nil) }
        load()
    }

    private func setPicture(_ image: UIImage?) {
        picture.image = image
        zoom.setZoomScale(1, animated: false)
        guard let image, image.size.width > 0 else { return }
        // The frame takes the screenshot's own shape (within reason for a very tall page).
        let ratio = min(2.2, max(0.3, image.size.height / image.size.width))
        aspect?.isActive = false
        let next = frameView.heightAnchor.constraint(equalTo: frameView.widthAnchor, multiplier: ratio)
        next.priority = .defaultHigh
        next.isActive = true
        aspect = next
    }

    private func load() {
        guard let shot = feed.shot, shot.id != loadedId || feed.loadAttempt != loadedAttempt else { return }
        loadedId = shot.id
        loadedAttempt = feed.loadAttempt
        loadTask?.cancel()
        let client = self.client, profile = feed.profile
        loadTask = Task { [weak self] in
            var image: UIImage?
            var gone = false
            if ToolScreenshots.isInline(shot.src) {
                image = await Self.decodeInline(shot.src)
                gone = image == nil                              // an inline picture that cannot be read never will be
            } else {
                // [load-cache] Past the media cache: the live feed's pictures are each shown once.
                do { image = try await ActivityMedia.loadFullDirect(client, shot.src, profile, nil) } catch {
                    // Only "the file is not there" is an expired capture; anything else is tried again by the feed.
                    gone = ScreenshotFeed.isGone(error)
                }
            }
            guard let self, !Task.isCancelled, feed.shot?.id == shot.id else { return }
            if let image {
                setPicture(image)
                feed.loaded(shot.id, ok: true)
            } else if gone {
                feed.loaded(shot.id, ok: false)
            } else {
                feed.loadFailed(shot.id)
            }
            render()
        }
    }

    @concurrent private static func decodeInline(_ source: String) async -> UIImage? {
        guard let comma = source.firstIndex(of: ","), let data = Data(base64Encoded: String(source[source.index(after: comma)...]), options: .ignoreUnknownCharacters),
              let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }

    // MARK: Zoom (pinch to 5×; double tap toggles 2.5× about the tap and fit)

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }

    @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
        guard picture.image != nil else { return }
        if zoom.zoomScale > 1.01 {
            zoom.setZoomScale(1, animated: !HQMotion.reduced)
        } else {
            let point = tap.location(in: picture)
            let size = CGSize(width: zoom.bounds.width / 2.5, height: zoom.bounds.height / 2.5)
            zoom.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
                      animated: !HQMotion.reduced)
        }
    }

    /// Test seam: the picture's zoom.
    var zoomScale: CGFloat { zoom.zoomScale }
}
