// The image viewer (docs/spec/1x-pages.md §5.6): full screen on black, paging across the current filter's images,
// pinch and double-tap zoom, fling up or down to close (`PhotoFling`); toolbar Share, Show in Chat, Info (name, chat, time, path, Copy Path).
// Owner 2026-11-22: press and hold (right-click on the Mac) on the image: Save to Photos, Share…, Copy Image, as a chat photo.

import UIKit

final class ArtifactImageViewer: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    private let records: [ArtifactRecord]
    private var index: Int
    private let previews: ArtifactPreviews
    private let showInChat: (ArtifactRecord) -> Void
    private let share: (ArtifactRecord, UIBarButtonItem) -> Void
    private let pages = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal,
                                             options: [.interPageSpacing: 16])
    private var fling: PhotoFling?
    /// [mac] Previous / next at the sides (round 2 #38); ← and → page everywhere.
    private var arrows: PhotoPagerArrows?

    init(records: [ArtifactRecord], index: Int, previews: ArtifactPreviews, showInChat: @escaping (ArtifactRecord) -> Void,
         share: @escaping (ArtifactRecord, UIBarButtonItem) -> Void) {
        self.records = records
        self.index = index
        self.previews = previews
        self.showInChat = showInChat
        self.share = share
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func wrap(_ viewer: ArtifactImageViewer) -> UINavigationController {
        let nav = UINavigationController(rootViewController: viewer)
        nav.modalPresentationStyle = .fullScreen
        nav.modalTransitionStyle = .crossDissolve
        nav.overrideUserInterfaceStyle = .dark
        nav.isToolbarHidden = false
        return nav
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "artifact.image"
        addChild(pages)
        pages.view.frame = view.bounds
        pages.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pages.view)
        pages.didMove(toParent: self)
        pages.dataSource = self
        pages.delegate = self
        pages.setViewControllers([page(index)], direction: .forward, animated: false)
        // [mac] Stress test 2026-10-28 #55: trailing on the Mac; owner 2026-11-18: filled there (`PhotoViewerChrome`).
        navigationItem.hqPlaceClose(PhotoViewerChrome.close(action: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        }))
        let share = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), primaryAction: nil)
        share.primaryAction = UIAction(image: UIImage(systemName: "square.and.arrow.up")) { [weak self, weak share] _ in
            guard let self, let share else { return }
            self.share(self.records[self.index], share)
        }
        share.accessibilityLabel = "Share"
        let chat = UIBarButtonItem(image: UIImage(systemName: "bubble.left"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            let record = self.records[self.index]
            self.dismiss(animated: true) { self.showInChat(record) }
        })
        chat.accessibilityLabel = "Show in Chat"
        let markup = UIBarButtonItem(image: UIImage(systemName: "pencil.tip.crop.circle"), primaryAction: UIAction { [weak self] _ in
            self?.openMarkup()
        })
        markup.accessibilityLabel = "Mark Up"
        markup.accessibilityIdentifier = "artifact.image.markup"
        let info = UIBarButtonItem(image: UIImage(systemName: "info.circle"), primaryAction: UIAction { [weak self] _ in self?.showInfo() })
        info.accessibilityLabel = "Info"
        toolbarItems = [share, .flexibleSpace(), markup, .flexibleSpace(), chat, .flexibleSpace(), info]
        // Fling up or down to close (owner 2026-11-19): the image follows the finger and flies off the way it's thrown.
        fling = PhotoFling(host: self, directions: [.up, .down], flyOff: true, content: { [weak self] in self?.pages.view },
                           canBegin: { [weak self] in (self?.pages.viewControllers?.first as? ZoomImagePage)?.isAtMinimumZoom ?? true })
        if records.count > 1 {
            arrows = PhotoPagerArrows(in: view, identifier: "artifact.image") { [weak self] in self?.step(forward: $0) }
        }
        updateTitle()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()   // ← and → reach `keyCommands` with nothing else holding the keyboard
    }

    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? { records.count > 1 ? UIKeyCommand.photoPaging(#selector(pageKey(_:))) : [] }

    @objc private func pageKey(_ command: UIKeyCommand) { step(forward: command.pagesForward) }

    /// ← / → and the Mac's buttons: the next or previous image, as a swipe would bring it (nothing past either end).
    private func step(forward: Bool) {
        guard let next = PhotoPaging.step(from: index, count: records.count, forward: forward) else { return }
        index = next
        pages.setViewControllers([page(next)], direction: forward ? .forward : .reverse, animated: !HQMotion.reduced)
        updateTitle()
    }

    private func page(_ i: Int) -> ZoomImagePage {
        let page = ZoomImagePage(record: records[i], index: i, previews: previews)
        page.onTap = { [weak self] in self?.toggleChrome() }
        page.imageMenu = { [weak self, weak page] record in
            guard let self, let page else { return nil }
            return MediaActions.menu(for: self.source(record), from: self, anchor: page.view)
        }
        return page
    }

    /// The image's bytes from the gateway, as a file named after it.
    private func source(_ record: ArtifactRecord) -> MediaSource {
        let previews = self.previews
        return MediaSource(name: record.label, explain: { ArtifactFiles.failureText($0, image: true) }) {
            let data = try await previews.imageData(record)
            return try MediaSource.temporaryFile(data, name: record.label)
        }
    }

    private func updateTitle() {
        title = records[index].label
        navigationItem.subtitle = records.count > 1 ? "\(index + 1) of \(records.count)" : nil
        arrows?.update(index: index, count: records.count, hidden: navigationController?.isNavigationBarHidden ?? false)
    }

    private func toggleChrome() {
        if PhotoViewerChrome.barsStay { return }   // [mac] Owner 2026-11-18: a click on the image took Done away
        let hidden = !(navigationController?.isNavigationBarHidden ?? false)
        navigationController?.setNavigationBarHidden(hidden, animated: true)
        navigationController?.setToolbarHidden(hidden, animated: true)
        arrows?.update(index: index, count: records.count, hidden: hidden)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let current = viewController as? ZoomImagePage, current.index > 0 else { return nil }
        return page(current.index - 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let current = viewController as? ZoomImagePage, current.index + 1 < records.count else { return nil }
        return page(current.index + 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let current = pages.viewControllers?.first as? ZoomImagePage else { return }
        index = current.index
        updateTitle()
    }

    private func openMarkup() {
        let record = records[index]
        Task { [weak self] in
            guard let self, let data = try? await self.previews.imageData(record), let image = UIImage(data: data) else { return }
            ImageMarkupController.present(image: image, mode: .apply(confirmTitle: "Share…"), from: self) { [weak self] edited, note in
                guard let self else { return }
                let items: [Any] = note.isEmpty ? [edited] : [edited, note]
                let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
                sheet.popoverPresentationController?.sourceItem = self.toolbarItems?.first
                self.present(sheet, animated: true)
            }
        }
    }

    private func showInfo() {
        let record = records[index]
        let when = Date(timeIntervalSince1970: record.timestamp / 1000)
        let message = [record.label, record.sessionTitle, JobWords.relativeDateTime(when), record.value].joined(separator: "\n")
        let sheet = UIAlertController(title: "Info", message: message, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Copy Path", style: .default) { [weak self] _ in
            UIPasteboard.general.string = record.value
            PagesHaptics.success()
            if let self { PagesHUD.show("Copied", symbol: "doc.on.doc", from: self) }
        })
        sheet.addAction(UIAlertAction(title: "Done", style: .cancel))
        sheet.popoverPresentationController?.sourceItem = toolbarItems?.last
        present(sheet, animated: true)
    }
}

/// One image: a zooming scroll view (pinch, double tap), a spinner until it lands, the reason when it can't.
final class ZoomImagePage: UIViewController, UIScrollViewDelegate {
    let record: ArtifactRecord
    let index: Int
    private let previews: ArtifactPreviews
    private let scroll = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let failure = UILabel()
    var onTap: (() -> Void)?
    /// The press-and-hold menu for this page's image (nil until it shows).
    var imageMenu: ((ArtifactRecord) -> UIMenu?)?
    private var menuInteraction: ViewerImageMenu?

    init(record: ArtifactRecord, index: Int, previews: ArtifactPreviews) {
        self.record = record
        self.index = index
        self.previews = previews
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var isAtMinimumZoom: Bool { scroll.zoomScale <= scroll.minimumZoomScale + 0.01 }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scroll.frame = PhotoViewerChrome.room(view)   // [mac] Owner 2026-11-18: between the bars on the Mac (layout)
        scroll.delegate = self
        PhotoViewerChrome.prepare(scroll)
        scroll.maximumZoomScale = 4
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        view.addSubview(scroll)
        imageView.contentMode = .scaleAspectFit
        imageView.accessibilityIdentifier = "artifact.image.view"
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = record.label
        scroll.addSubview(imageView)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        failure.textColor = .white
        failure.numberOfLines = 0
        failure.textAlignment = .center
        failure.font = HQFont.preferred(.body)
        failure.translatesAutoresizingMaskIntoConstraints = false
        failure.isHidden = true
        view.addSubview(failure)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            failure.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            failure.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            failure.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        view.addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        single.require(toFail: double)
        view.addGestureRecognizer(single)
        let menu = ViewerImageMenu { [weak self] in
            guard let self, self.imageView.image != nil else { return nil }
            return self.imageMenu?(self.record)
        }
        menu.attach(to: imageView)
        menuInteraction = menu
        if case .image(let thumb) = previews.state(record) { show(thumb) }
        spinner.startAnimating()
        Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await self.previews.fullImage(self.record)
                self.spinner.stopAnimating()
                self.show(image)
            } catch {
                self.spinner.stopAnimating()
                if self.imageView.image == nil {
                    self.failure.text = ArtifactFiles.failureText(error, image: true)
                    self.failure.isHidden = false
                    if ArtifactFiles.isHostedElsewhere(error) { self.addOpenButton() }
                }
            }
        }
    }

    /// An image on another site (not fetched here, `RemoteImageFetch`): Open hands its link to the browser.
    private func addOpenButton() {
        guard let url = URL(string: record.value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        var config = UIButton.Configuration.hqGlass()
        config.title = "Open"
        config.image = UIImage(systemName: "safari")
        config.imagePadding = 6
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in LinkOpener.openOutside(url) })
        button.accessibilityIdentifier = "artifact.image.open"
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: failure.bottomAnchor, constant: 16),
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    private func show(_ image: UIImage) {
        imageView.image = image
        layoutImage()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let room = PhotoViewerChrome.room(view)
        if scroll.frame != room { scroll.frame = room }
        layoutImage()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        if DeviceWord.isMac { view.setNeedsLayout() }
    }

    private func layoutImage() {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return }
        let bounds = scroll.bounds.size
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        if scroll.zoomScale == 1 {
            imageView.frame = CGRect(origin: .zero, size: size)
            scroll.contentSize = size
        }
        center()
    }

    private func center() {
        let bounds = scroll.bounds.size, content = imageView.frame.size
        scroll.contentInset = UIEdgeInsets(top: max(0, (bounds.height - content.height) / 2), left: max(0, (bounds.width - content.width) / 2),
                                           bottom: 0, right: 0)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

    @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
        if scroll.zoomScale > 1.01 {
            scroll.setZoomScale(1, animated: true)
        } else {
            let point = tap.location(in: imageView)
            let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
            scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }

    @objc private func singleTapped() { onTap?() }
}
