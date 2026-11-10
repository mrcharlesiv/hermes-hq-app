import UIKit

// The full-screen photo viewer (docs/spec/1x-attachments.md §9): presented with the system zoom transition from the
// tapped photo (swipe down or pinch in to dismiss, back into the cell), pages across the message's photos, pinch to
// 5×, double-tap 2.5× at the finger, single tap shows/hides the chrome. System bars: Close and "2 of 3" on top, Share
// and Save below. It shows the cell's picture at once and the original decoded at the screen's size as it arrives.

final class MediaViewerController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    private let items: [MediaItem]
    private(set) var index: Int
    private let pages: UIPageViewController
    private var chromeHidden = false
    private var saveItem: UIBarButtonItem!
    private var shareItem: UIBarButtonItem!
    private var restoreSave: DispatchWorkItem?
    /// [mac] Previous / next at the sides (round 2 #38); ← and → page everywhere.
    private var arrows: PhotoPagerArrows?

    /// Presents the viewer over `presenter`, zooming from `source(index)` (nil → a plain cover).
    static func present(from presenter: UIViewController, items: [MediaItem], index: Int, source: @escaping (Int) -> UIView?) {
        guard !items.isEmpty else { return }
        let viewer = MediaViewerController(items: items, index: min(max(0, index), items.count - 1))
        let nav = UINavigationController(rootViewController: viewer)
        nav.modalPresentationStyle = .fullScreen
        nav.overrideUserInterfaceStyle = .dark          // bars and title read on the black page
        nav.setToolbarHidden(false, animated: false)
        let options = UIViewController.Transition.ZoomOptions()
        // Swipe down / pinch in dismiss only at the fitted size (a zoomed photo pans instead). With several photos a
        // sideways swipe pages, even from the screen's edge: only a mostly-downward one closes.
        options.interactiveDismissShouldBegin = { [weak viewer] context in
            guard let viewer else { return true }
            if viewer.items.count > 1, abs(context.velocity.dx) > abs(context.velocity.dy) { return false }
            return viewer.currentPage?.isAtMinimumZoom ?? true
        }
        nav.preferredTransition = .zoom(options: options) { [weak viewer] _ in
            guard let viewer else { return nil }
            return source(viewer.index)
        }
        presenter.present(nav, animated: true)
    }

    init(items: [MediaItem], index: Int) {
        self.items = items
        self.index = index
        pages = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal,
                                     options: [.interPageSpacing: 12])
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var currentPage: MediaPageController? { pages.viewControllers?.first as? MediaPageController }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        addChild(pages)
        pages.view.frame = view.bounds
        pages.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pages.view)
        pages.didMove(toParent: self)
        pages.dataSource = items.count > 1 ? self : nil
        pages.delegate = self
        pages.setViewControllers([page(index)], direction: .forward, animated: false)

        let close = UIBarButtonItem.hqClose(action: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        close.accessibilityLabel = "Close"
        close.accessibilityIdentifier = "viewer.close"
        navigationItem.hqPlaceClose(close)   // [mac] Stress test 2026-10-28 #55: trailing on the Mac
        shareItem = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), primaryAction: UIAction { [weak self] _ in self?.share() })
        shareItem.accessibilityLabel = "Share"
        shareItem.accessibilityIdentifier = "viewer.share"
        saveItem = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.down"), primaryAction: UIAction { [weak self] _ in self?.save() })
        saveItem.accessibilityLabel = "Save"
        saveItem.accessibilityIdentifier = "viewer.save"
        toolbarItems = [shareItem, .flexibleSpace(), saveItem]
        if items.count > 1 { arrows = PhotoPagerArrows(in: view, identifier: "viewer") { [weak self] in self?.step(forward: $0) } }
        updateTitle()
        view.accessibilityIdentifier = "viewer"
        AppLog.trace("chatui", "media viewer opened: \(items.count) item(s) (\(Self.kindsSummary(items))), showing \(index + 1)")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()   // ← and → reach `keyCommands` with nothing else holding the keyboard
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Catches Close, the system swipe-down/pinch-in dismiss, and VoiceOver's escape gesture alike.
        if isBeingDismissed || navigationController?.isBeingDismissed == true || parent == nil {
            AppLog.trace("chatui", "media viewer closed at \(index + 1) of \(items.count)")
        }
    }

    /// For logs only: how many of each attachment kind, never a name.
    private static func kindsSummary(_ items: [MediaItem]) -> String {
        var counts: [String: Int] = [:]
        for item in items { counts["\(item.attachment.kind)", default: 0] += 1 }
        return counts.sorted(by: { $0.key < $1.key }).map { "\($0.value) \($0.key)" }.joined(separator: ", ")
    }

    private func page(_ i: Int) -> MediaPageController {
        let page = MediaPageController(item: items[i], index: i)
        page.onSingleTap = { [weak self] in self?.toggleChrome() }
        return page
    }

    private func updateTitle() {
        title = items.count > 1 ? "\(index + 1) of \(items.count)" : nil
        arrows?.update(index: index, count: items.count, hidden: chromeHidden)
    }

    override var prefersStatusBarHidden: Bool { chromeHidden }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    /// VoiceOver's two-finger scrub closes the viewer, as Close does.
    override func accessibilityPerformEscape() -> Bool {
        dismiss(animated: true)
        return true
    }

    private func toggleChrome() {
        // Under VoiceOver activating the photo keeps Close, Share and Save where they are.
        if HQAccessibility.voiceOver && !chromeHidden { return }
        chromeHidden.toggle()
        arrows?.update(index: index, count: items.count, hidden: chromeHidden)
        navigationController?.setNavigationBarHidden(chromeHidden, animated: true)
        navigationController?.setToolbarHidden(chromeHidden, animated: true)
        UIView.animate(withDuration: 0.2) { self.setNeedsStatusBarAppearanceUpdate() } // motion-ok: the status bar fades
    }

    // MARK: Paging

    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? { items.count > 1 ? UIKeyCommand.photoPaging(#selector(pageKey(_:))) : [] }

    @objc private func pageKey(_ command: UIKeyCommand) { step(forward: command.pagesForward) }

    /// ← / → and the Mac's buttons: the next or previous photo, as a swipe would bring it (nothing past either end).
    private func step(forward: Bool) {
        guard let next = PhotoPaging.step(from: index, count: items.count, forward: forward) else { return }
        index = next
        pages.setViewControllers([page(next)], direction: forward ? .forward : .reverse, animated: !HQMotion.reduced)
        updateTitle()
    }

    func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
        guard let p = vc as? MediaPageController, p.index > 0 else { return nil }
        return page(p.index - 1)
    }

    func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
        guard let p = vc as? MediaPageController, p.index + 1 < items.count else { return nil }
        return page(p.index + 1)
    }

    func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController],
                            transitionCompleted completed: Bool) {
        guard completed, let p = currentPage else { return }
        index = p.index
        updateTitle()
    }

    // MARK: Share / Save (spec §9.4, §9.5)

    /// "Saved" with a checkmark for 1.8 s (a new item, so the bar and VoiceOver both pick the change up).
    private func showSaved(_ saved: Bool) {
        let item = UIBarButtonItem(image: UIImage(systemName: saved ? "checkmark" : "square.and.arrow.down"),
                                   primaryAction: UIAction { [weak self] _ in self?.save() })
        item.accessibilityLabel = saved ? "Saved" : "Save"
        item.accessibilityIdentifier = "viewer.save"
        saveItem = item
        toolbarItems = [shareItem, .flexibleSpace(), item]
    }

    private func share() {
        let item = items[index]
        Task { await MediaActions.share(item, from: self, anchor: nil, barItem: shareItem) }
    }

    private func save() {
        let item = items[index]
        Task { [weak self] in
            let outcome = await MediaActions.save(item)
            guard let self else { return }
            switch outcome {
            case .saved:
                Haptics.play(.success)
                self.showSaved(true)
                restoreSave?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.showSaved(false) }
                restoreSave = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
            case .denied:
                MediaActions.showSaveDenied(on: self)
            case .failed(let message):
                MediaActions.showFailure("Couldn’t Save", message: message, on: self) { [weak self] in self?.save() }
            }
        }
    }
}

/// One photo, zoomable (spec §9.2).
final class MediaPageController: UIViewController, UIScrollViewDelegate {
    let item: MediaItem
    let index: Int
    var onSingleTap: (() -> Void)?

    private let scroll = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var loadTask: Task<Void, Never>?
    private var fitted = false
    /// Over the preview when the full size didn't load: what happened, and a tap tries again.
    private var failedCaption: UIButton?

    init(item: MediaItem, index: Int) {
        self.item = item
        self.index = index
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit { loadTask?.cancel() }

    var isAtMinimumZoom: Bool { scroll.zoomScale <= scroll.minimumZoomScale + 0.01 }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scroll.delegate = self
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.bouncesZoom = true
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.decelerationRate = .fast
        view.addSubview(scroll)
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = item.label
        imageView.accessibilityTraits = .image
        scroll.addSubview(imageView)
        spinner.color = .white
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        single.require(toFail: double)
        scroll.addGestureRecognizer(single)
        load()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if scroll.frame != view.bounds {
            scroll.frame = view.bounds
            fitted = false
        }
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        if !fitted { fit() }
    }

    private func load() {
        guard let context = item.context else {
            // No account to read it with (a group room's reply picture): say so, instead of a black page that never fills.
            AppLog.note("chatui", "media viewer: no media context for \(item.attachment.kind)")
            if imageView.image == nil { showFailure("This picture can’t be opened from this chat.", retry: false) }
            return
        }
        showFailure(nil)
        let side = max(view.bounds.width, view.bounds.height, 430)
        let target = min(4096, Int(side * max(2, traitCollection.displayScale) * 3))
        if imageView.image == nil, let cached = MediaLoader.shared.cachedImage(item.attachment, context: context, maxPixel: 256) { show(cached) }
        let started = CACurrentMediaTime()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.loadTask != nil else { return }
            self.spinner.startAnimating()
        }
        loadTask = Task { [weak self] in
            let result: Result<UIImage, Error>
            do {
                let loaded = try await MediaLoader.shared.image(self?.item.attachment ?? MessageAttachment(kind: .image, source: .tooLarge, name: ""),
                                                                context: context, maxPixel: target, cache: false)   // [perf] the page holds it
                result = .success(loaded.image)
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            self.loadTask = nil
            self.spinner.stopAnimating()
            switch result {
            case .success(let image):
                self.show(image)
                AppLog.trace("chatui", "media loaded \(self.item.attachment.kind): \(self.item.attachment.byteSize.map(String.init) ?? "?") bytes")
            case .failure(let error):
                if error is CancellationError { return }
                let known = (error as? MediaLoadError).map { String(describing: $0) } ?? "\(type(of: error))"
                AppLog.note("chatui", "media load failed (\(known)): \(self.item.attachment.kind), \(self.imageView.image == nil ? "no preview shown" : "kept the preview")")
                // The same words Share uses when the file can't be fetched (it failed silently: a black page, or a
                // blurry preview with no sign the full size didn't come).
                self.showFailure((error as? MediaLoadError)?.fileMessage ?? MediaLoadError.unreachable.fileMessage)
            }
            _ = started
        }
    }

    /// nil clears it. With no picture: a centred message and Try Again (unless trying again can't help); over a
    /// preview: a small caption that retries.
    private func showFailure(_ message: String?, retry canRetry: Bool = true) {
        guard let message else {
            contentUnavailableConfiguration = nil
            failedCaption?.removeFromSuperview()
            failedCaption = nil
            return
        }
        let retry = UIAction { [weak self] _ in self?.load() }
        if imageView.image == nil {
            var config = UIContentUnavailableConfiguration.empty().hqScaled()
            config.image = UIImage(systemName: "photo")
            config.text = "Couldn’t Load the Photo"
            config.secondaryText = message
            if canRetry {
                var button = UIButton.Configuration.hqGlass()
                button.title = "Try Again"
                config.button = button
                config.buttonProperties.primaryAction = retry
            }
            contentUnavailableConfiguration = config
            return
        }
        var config = UIButton.Configuration.hqGlass()   // [glass] the Desktop Look's outlined button, never glass, there
        config.title = "Showing a Preview"
        config.subtitle = message
        config.image = UIImage(systemName: "arrow.clockwise")
        config.imagePadding = 8
        config.titleAlignment = .leading
        let caption = UIButton(configuration: config, primaryAction: retry)
        caption.accessibilityHint = "Tries to load the full-size photo again"
        caption.accessibilityIdentifier = "viewer.retry"
        caption.titleLabel?.numberOfLines = 0
        caption.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(caption)
        NSLayoutConstraint.activate([
            caption.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            caption.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            caption.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
        failedCaption = caption
    }

    private func show(_ image: UIImage) {
        let first = imageView.image == nil
        imageView.image = image
        if first || isAtMinimumZoom { fitted = false; view.setNeedsLayout() }
    }

    /// Aspect-fit at the minimum zoom, 5 × that at the most; centred while smaller than the screen.
    private func fit() {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0, view.bounds.width > 0 else { return }
        fitted = true
        scroll.zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: image.size)
        scroll.contentSize = image.size
        let fit = min(view.bounds.width / image.size.width, view.bounds.height / image.size.height)
        scroll.minimumZoomScale = fit
        scroll.maximumZoomScale = fit * 5
        scroll.zoomScale = fit
        center()
    }

    private func center() {
        let w = imageView.frame.width, h = imageView.frame.height
        let insetX = max(0, (scroll.bounds.width - w) / 2), insetY = max(0, (scroll.bounds.height - h) / 2)
        scroll.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

    @objc private func doubleTapped(_ gr: UITapGestureRecognizer) {
        if !isAtMinimumZoom {
            scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
            return
        }
        let scale = min(scroll.maximumZoomScale, scroll.minimumZoomScale * 2.5)
        let point = gr.location(in: imageView)
        let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
        scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }

    @objc private func singleTapped() { onSingleTap?() }
}

/// The viewer as other streams open it (spec §13.4 seam: activity cards): `items` are reply media refs.
enum MediaViewer {
    static func present(from view: UIView, items: [MediaRef], index: Int, context: MediaContext?) {
        var responder: UIResponder? = view
        while let r = responder, !(r is UIViewController) { responder = r.next }
        guard let presenter = responder as? UIViewController else { return }
        let media = items.filter { $0.kind == .image }.map { MediaItem(attachment: $0.attachment, index: -1, context: context, label: $0.label) }
        MediaViewerController.present(from: presenter, items: media, index: index) { [weak view] _ in view }
    }
}
