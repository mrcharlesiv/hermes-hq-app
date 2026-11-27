// A photo file already on the phone, full screen (owner 2026-11-22: a photo opened from Files came up in Quick Look and
// "I kept swiping and then swiping harder" — it had no swipe to close, and its Done hid until a tap). Quick Look draws
// the file in another process, so no gesture of the app's ever sees a swipe over it: a photo file opens here instead,
// as the chat's and Artifacts' viewers show a photo. Black, pinch and double-tap zoom, a tap hides the bars, fling up or
// down to close (`PhotoFling`); Close on top, Share below. PDFs, films and other files keep Quick Look.

import UIKit

final class LocalPhotoViewer: UIViewController, UIScrollViewDelegate {
    private let url: URL
    private let scroll = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var fling: PhotoFling?

    /// Whether a file opens here rather than in Quick Look: a photo by its name (the decode decides the rest).
    static func opens(_ url: URL) -> Bool { MediaKinds.kind(ofName: url.lastPathComponent) == .image }

    /// Presents the photo over `presenter`; Quick Look (`fallback`) when it doesn't decode.
    static func present(_ url: URL, from presenter: UIViewController, fallback: @escaping @MainActor () -> Void) {
        Task { @MainActor [weak presenter] in
            // Decoded at about the screen's size and a little over, for zooming (a 40-megapixel photo stays light).
            let image = await ArtifactThumbs.read(url, maxPixels: 4096)
            guard let presenter, presenter.view.window != nil else { return }
            guard let image else { fallback(); return }
            let viewer = LocalPhotoViewer(url: url, image: image)
            let nav = UINavigationController(rootViewController: viewer)
            nav.modalPresentationStyle = .fullScreen
            nav.modalTransitionStyle = .crossDissolve
            nav.overrideUserInterfaceStyle = .dark
            nav.isToolbarHidden = false
            AppLog.trace("chatui", "photo file opened in the photo viewer")
            presenter.present(nav, animated: true)
        }
    }

    private init(url: URL, image: UIImage) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
        imageView.image = image
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var isAtMinimumZoom: Bool { scroll.zoomScale <= scroll.minimumZoomScale + 0.01 }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "file.photo"
        title = url.lastPathComponent
        scroll.frame = PhotoViewerChrome.room(view)
        scroll.delegate = self
        PhotoViewerChrome.prepare(scroll)
        scroll.maximumZoomScale = 4
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        view.addSubview(scroll)
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "Photo, \(url.lastPathComponent)"
        imageView.accessibilityIdentifier = "file.photo.image"
        scroll.addSubview(imageView)
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        view.addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        single.require(toFail: double)
        view.addGestureRecognizer(single)

        let close = PhotoViewerChrome.close(action: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        close.accessibilityLabel = "Close"
        close.accessibilityIdentifier = "file.photo.close"
        navigationItem.hqPlaceClose(close)
        let share = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), primaryAction: nil)
        share.primaryAction = UIAction(image: UIImage(systemName: "square.and.arrow.up")) { [weak self, weak share] _ in
            guard let self else { return }
            let sheet = UIActivityViewController(activityItems: [self.url], applicationActivities: nil)
            sheet.popoverPresentationController?.barButtonItem = share
            self.present(sheet, animated: true)
        }
        share.accessibilityLabel = "Share"
        share.accessibilityIdentifier = "file.photo.share"
        let markup = UIBarButtonItem(image: UIImage(systemName: "pencil.tip.crop.circle"), primaryAction: UIAction { [weak self] _ in
            self?.openMarkup()
        })
        markup.accessibilityLabel = "Mark Up"
        markup.accessibilityIdentifier = "file.photo.markup"
        toolbarItems = [share, .flexibleSpace(), markup]
        // Fling up or down to close: the photo follows the finger and flies off the way it's thrown.
        fling = PhotoFling(host: self, directions: [.up, .down], flyOff: true, content: { [weak self] in self?.scroll },
                           canBegin: { [weak self] in self?.isAtMinimumZoom ?? true })
    }

    private func openMarkup() {
        guard let image = imageView.image else { return }
        ImageMarkupController.present(image: image, mode: .apply(confirmTitle: "Share…"), from: self) { [weak self] edited, note in
            guard let self else { return }
            let items: [Any] = note.isEmpty ? [edited] : [edited, note]
            let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
            sheet.popoverPresentationController?.barButtonItem = self.toolbarItems?.last
            self.present(sheet, animated: true)
        }
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

    @objc private func singleTapped() {
        if PhotoViewerChrome.barsStay { return }
        let hidden = !(navigationController?.isNavigationBarHidden ?? false)
        navigationController?.setNavigationBarHidden(hidden, animated: true)
        navigationController?.setToolbarHidden(hidden, animated: true)
    }
}
