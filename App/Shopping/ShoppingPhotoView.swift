import UIKit

// [shopping] A product's photo: loaded through the chat's remote image path (MediaLoader `.remote`, which takes
// public https only, RemoteImagePolicy), filling its frame. No photo, or one that fails, is a quiet placeholder glyph.

final class ShoppingPhotoView: UIView {
    /// The photos are public web images, not a gateway's files: one shared cache for them, whatever the chat.
    static let context = MediaContext(accountId: "shopping-photos", profile: "web")

    private let imageView = UIImageView()
    private let placeholder = UIImageView()
    private var url: URL?
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
        guard url != self.url || (imageView.image == nil && task == nil) else { return }
        task?.cancel()
        task = nil
        self.url = url
        imageView.image = nil
        placeholder.isHidden = false
        guard let url else { return }
        let attachment = MessageAttachment(kind: .image, source: .remote(url), name: url.lastPathComponent.isEmpty ? "Photo" : url.lastPathComponent)
        let maxPixel = Int(ceil(maxPoints * max(2, traitCollection.displayScale)))
        if let hit = MediaLoader.shared.cachedImage(attachment, context: Self.context, maxPixel: maxPixel) {
            show(hit)
            return
        }
        task = Task { [weak self] in
            let loaded = try? await MediaLoader.shared.image(attachment, context: Self.context, maxPixel: maxPixel)
            guard let self, !Task.isCancelled, self.url == url else { return }
            self.task = nil
            if let loaded { self.show(loaded.image) }
        }
    }

    private func show(_ image: UIImage) {
        imageView.image = image
        placeholder.isHidden = true
    }

    /// The cell went away: no load runs on for it.
    func reset() {
        task?.cancel()
        task = nil
        url = nil
        imageView.image = nil
        placeholder.isHidden = false
    }
}
