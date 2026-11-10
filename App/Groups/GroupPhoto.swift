// [groups] A room's photo (docs/spec/3x-groups.md §7.2, §7.5): the picked image cropped square and re-encoded as a JPEG
// data URL of at most 24,000 characters, since a longer one is left out of the mirror (§5.1). The system photo picker
// runs out of process, so the app asks for no photo permission.

import PhotosUI
import UIKit

nonisolated enum GroupPhoto {
    static let prefix = "data:image/jpeg;base64,"
    /// Sides and qualities tried in order: 256 px at 0.8 first, stepping down until the data URL fits.
    static let sides: [CGFloat] = [256, 224, 192, 160, 128, 112, 96, 80, 64, 48]
    static let qualities: [CGFloat] = [0.8, 0.7, 0.6, 0.5, 0.4, 0.3]

    /// The centre square of `image`, drawn at `side` pixels.
    static func square(_ image: UIImage, side: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let source = image.size
            guard source.width > 0, source.height > 0 else { return }
            let scale = max(side / source.width, side / source.height)
            let drawn = CGSize(width: source.width * scale, height: source.height * scale)
            image.draw(in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2, width: drawn.width, height: drawn.height))
        }
    }

    /// The data URL of `image`, at most `limit` characters; nil when even the smallest try does not fit.
    static func dataURL(from image: UIImage, limit: Int = GroupLimits.syncImage) -> String? {
        for side in sides {
            let squared = square(image, side: side)
            for quality in qualities {
                guard let data = squared.jpegData(compressionQuality: quality) else { continue }
                // Base64 is 4 characters for every 3 bytes: skip the encode when it cannot fit.
                guard prefix.count + (data.count + 2) / 3 * 4 <= limit else { continue }
                return prefix + data.base64EncodedString()
            }
        }
        return nil
    }
}

/// Presents the system photo picker and hands back the picked image as a room photo.
@MainActor final class GroupPhotoPicker: NSObject, PHPickerViewControllerDelegate {
    private var done: ((String?) -> Void)?
    private weak var host: UIViewController?
    private static var live: GroupPhotoPicker?

    /// `done` gets the data URL, or nil when the image could not be read; it is not called when the picker is cancelled.
    static func present(from host: UIViewController, done: @escaping (String?) -> Void) {
        let picker = GroupPhotoPicker()
        picker.done = done
        picker.host = host
        live = picker
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let controller = PHPickerViewController(configuration: config)
        controller.delegate = picker
        host.present(controller, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { Self.live = nil; return }
        guard provider.canLoadObject(ofClass: UIImage.self) else { Self.finish(nil); return }
        // Decoding and re-encoding run off the main thread; only the data URL comes back.
        _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
            let url = (object as? UIImage).flatMap { GroupPhoto.dataURL(from: $0) }
            Task { @MainActor in GroupPhotoPicker.finish(url) }
        }
    }

    private static func finish(_ url: String?) {
        let picker = live
        live = nil
        picker?.done?(url)
    }

    /// The alert for an image that could not be read or made small enough.
    static func failed(from host: UIViewController) {
        FailureAlert.present(title: "Couldn’t Use That Photo", reason: "The photo could not be read. Choose another one.", from: host)
    }
}
