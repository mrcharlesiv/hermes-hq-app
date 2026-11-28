import UIKit

// [shopping] A product's or hotel's photo: tries each supplied image URL in order through the chat's remote image path
// (MediaLoader `.remote`, public https only, RemoteImagePolicy), and when none was given or all fail, resolves a
// fallback photo from the store/hotel page (ProductPhotoResolver, bounded cookieless https). No photo, or one that
// fails everywhere, is a quiet placeholder glyph.

final class ShoppingPhotoView: UIView {
    /// The photos are public web images, not a gateway's files: one shared cache for them, whatever the chat.
    static let context = MediaContext(accountId: "shopping-photos", profile: "web")

    private struct RequestKey: Equatable {
        var images: [URL]
        var fallbackPages: [URL]
    }

    private let imageView = UIImageView()
    private let placeholder = UIImageView()
    private var requestKey: RequestKey?
    private var task: Task<Void, Never>?

    /// [travel] The whole picture inside the frame, not a crop that fills it: a full-screen viewer shows all of a photo.
    var fits = false { didSet { imageView.contentMode = fits ? .scaleAspectFit : .scaleAspectFill } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        backgroundColor = ChatPalette.fill3
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)
        placeholder.contentMode = .center
        placeholder.tintColor = ChatPalette.label3
        addSubview(placeholder)
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        placeholder.frame = bounds
        let side = max(12, min(34, min(bounds.width, bounds.height) * 0.32))
        placeholder.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: side, weight: .light)
        placeholder.image = UIImage(systemName: "photo")
    }

    /// Shows `url`'s picture (nil: the placeholder). The same url again keeps what is shown.
    func set(_ url: URL?, maxPoints: CGFloat) {
        set(images: url.map { [$0] } ?? [], fallbackPages: [], maxPoints: maxPoints)
    }

    /// Shows the first loadable picture from `images`, falling back to discovering a photo from `fallbackPages`
    /// (store/offer or hotel pages) when `images` is empty or every supplied image fails to load.
    func set(images: [URL], fallbackPages: [URL] = [], maxPoints: CGFloat) {
        let key = RequestKey(images: images, fallbackPages: fallbackPages)
        guard key != requestKey || (imageView.image == nil && task == nil) else { return }
        task?.cancel()
        task = nil
        requestKey = key
        imageView.image = nil
        placeholder.isHidden = false

        let maxPixel = Int(ceil(maxPoints * max(2, traitCollection.displayScale)))
        var quickCandidates = images
        if let cachedFallback = ProductPhotoResolver.cachedResolved(for: fallbackPages),
           !quickCandidates.contains(cachedFallback) {
            quickCandidates.append(cachedFallback)
        }
        for url in quickCandidates {
            let attachment = Self.attachment(for: url)
            if let hit = MediaLoader.shared.cachedImage(attachment, context: Self.context, maxPixel: maxPixel) {
                show(hit)
                return
            }
        }
        guard !quickCandidates.isEmpty || !fallbackPages.isEmpty else { return }

        task = Task { [weak self] in
            var tried: Set<URL> = []
            for url in quickCandidates {
                guard !Task.isCancelled else { return }
                tried.insert(url)
                if let loaded = try? await MediaLoader.shared.image(Self.attachment(for: url), context: Self.context, maxPixel: maxPixel) {
                    guard let self, !Task.isCancelled, self.requestKey == key else { return }
                    self.task = nil
                    self.show(loaded.image)
                    return
                }
            }
            guard !fallbackPages.isEmpty, !Task.isCancelled else {
                if let self, self.requestKey == key { self.task = nil }
                return
            }
            let discovered = await ProductPhotoResolver.shared.candidates(for: fallbackPages)
            for url in discovered where !tried.contains(url) {
                guard !Task.isCancelled else { return }
                tried.insert(url)
                if let loaded = try? await MediaLoader.shared.image(Self.attachment(for: url), context: Self.context, maxPixel: maxPixel) {
                    ProductPhotoResolver.rememberResolved(url, for: fallbackPages)
                    guard let self, !Task.isCancelled, self.requestKey == key else { return }
                    self.task = nil
                    self.show(loaded.image)
                    return
                }
            }
            if let self, self.requestKey == key { self.task = nil }
        }
    }

    private static func attachment(for url: URL) -> MessageAttachment {
        MessageAttachment(kind: .image, source: .remote(url), name: url.lastPathComponent.isEmpty ? "Photo" : url.lastPathComponent)
    }

    private func show(_ image: UIImage) {
        imageView.image = image
        placeholder.isHidden = true
    }

    /// The cell went away: no load runs on for it.
    func reset() {
        task?.cancel()
        task = nil
        requestKey = nil
        imageView.image = nil
        placeholder.isHidden = false
    }
}
