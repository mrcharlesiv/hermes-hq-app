// Picked items → prepared attachments on the phone (docs/spec/1x-attachments.md §4.2–§4.5, §5): photos through the
// normaliser (library, camera, paste, and images picked from Files, A3), videos copied and stripped of their
// location, other files copied under their safe names. Each attachment gets its own UUID folder; a failed item's
// partial copy is deleted at once. Everything here runs off the main thread.

import Foundation
import UniformTypeIdentifiers
import CoreGraphics
import UIKit

nonisolated enum AttachmentImporter {
    /// The kinds of source a pick hands over.
    enum Source: Sendable {
        /// A photo file (library, paste, an image from Files): normalised, named `<stem>.jpg|png|gif`.
        case photo(URL, stem: String)
        /// A movie (library): copied, location removed; a file attachment.
        case movie(URL, name: String)
        /// Anything from Files: an image ImageIO opens goes the photo path, everything else is copied as a file.
        case file(URL, name: String)
        /// A camera capture as taken (oriented and scaled down here, off the main thread).
        case camera(UIImage)
    }

    /// A placeholder tile while the import runs.
    static func placeholder(id: String, kind: DraftAttachment.Kind, name: String) -> DraftAttachment {
        DraftAttachment(id: id, kind: kind, name: name, localFile: "\(id)/\(name)", byteSize: 0, pixelWidth: nil, pixelHeight: nil,
                        typeIdentifier: UTType.data.identifier, upload: .preparing(fraction: nil))
    }

    /// Prepares `source` as attachment `id` in `staging`. Throws `AttachmentPrepareError` (the alert's reason).
    static func prepare(_ source: Source, id: String, staging: AttachmentStaging) async throws -> DraftAttachment {
        do {
            try Task.checkCancellation()
            switch source {
            case .photo(let url, let stem):
                return try photo(url, stem: stem, id: id, staging: staging)
            case .camera(let image):
                guard let oriented = oriented(image) else { throw AttachmentPrepareError.cameraNotSaved }
                try Task.checkCancellation()
                let folder = try staging.makeFolder(id)
                let out = try PhotoNormalizer.encodeJPEG(oriented, into: folder, name: "camera.jpg")
                return attachment(id: id, kind: .image, out: out)
            case .movie(let url, let name):
                let safe = AttachmentStaging.safeName(name)
                let copied = try staging.copyIn(url, id: id, name: safe)
                try Task.checkCancellation()
                try await VideoSanitizer.removeLocation(fromMovieAt: copied)
                return try fileAttachment(id: id, url: copied, name: safe)
            case .file(let url, let name):
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                let safe = AttachmentStaging.safeName(name)
                guard size <= AttachmentStaging.maxItemBytes else { throw AttachmentPrepareError.tooLarge(name: safe) }
                if PhotoNormalizer.canNormalize(url) {
                    return try photo(url, stem: AttachmentStaging.stem(safe), id: id, staging: staging)
                }
                guard FileManager.default.isReadableFile(atPath: url.path) else { throw AttachmentPrepareError.unreadableFile }
                let copied = try staging.copyIn(url, id: id, name: safe)
                return try fileAttachment(id: id, url: copied, name: safe)
            }
        } catch let error as AttachmentPrepareError {
            staging.remove(id)
            throw error
        } catch is CancellationError {
            staging.remove(id)
            throw AttachmentPrepareError.cancelled
        } catch {
            staging.remove(id)
            switch source {
            case .photo, .camera: AppLog.swallowed("transfer", "prepare a picked photo", error); throw AttachmentPrepareError.unreadablePhoto
            case .movie: AppLog.swallowed("transfer", "prepare a picked movie", error); throw AttachmentPrepareError.unreadablePhoto
            case .file: AppLog.swallowed("transfer", "prepare a picked file", error); throw AttachmentPrepareError.unreadableFile
            }
        }
    }

    /// The camera image with its orientation drawn into the pixels, at most 3072 px on the long side (spec §4.3).
    /// `UIGraphicsImageRenderer` is safe off the main thread; this runs on the import's detached task.
    static func oriented(_ image: UIImage) -> CGImage? {
        let longest = max(image.size.width * image.scale, image.size.height * image.scale)
        let factor = min(1, CGFloat(PhotoNormalizer.maxPixel) / max(1, longest))
        let size = CGSize(width: (image.size.width * image.scale * factor).rounded(),
                          height: (image.size.height * image.scale * factor).rounded())
        guard size.width >= 1, size.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }

    private static func photo(_ url: URL, stem: String, id: String, staging: AttachmentStaging) throws -> DraftAttachment {
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        // A source over the limit is still fine when the normalised copy fits (a 50 MB RAW becomes a ~3 MB JPEG);
        // only absurd inputs are refused before decoding.
        guard size <= 512 << 20 else { throw AttachmentPrepareError.tooLarge(name: stem + ".jpg") }
        let folder = try staging.makeFolder(id)
        let out = try PhotoNormalizer.normalize(url, stem: stem, into: folder)
        return attachment(id: id, kind: .image, out: out)
    }

    private static func attachment(id: String, kind: DraftAttachment.Kind, out: PhotoNormalizer.Output) -> DraftAttachment {
        DraftAttachment(id: id, kind: kind, name: out.name, localFile: "\(id)/\(out.name)", byteSize: out.byteSize,
                        pixelWidth: out.pixelWidth, pixelHeight: out.pixelHeight, typeIdentifier: out.typeIdentifier, upload: .waiting)
    }

    private static func fileAttachment(id: String, url: URL, name: String) throws -> DraftAttachment {
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard size <= AttachmentStaging.maxItemBytes else { throw AttachmentPrepareError.tooLarge(name: name) }
        let type = UTType(filenameExtension: (name as NSString).pathExtension)?.identifier ?? UTType.data.identifier
        return DraftAttachment(id: id, kind: .file, name: name, localFile: "\(id)/\(name)", byteSize: size, pixelWidth: nil,
                               pixelHeight: nil, typeIdentifier: type, upload: .waiting)
    }

    /// The tray thumbnail for a prepared photo (spec §5.2): 64 pt × screen scale, memory only.
    static func thumbnail(_ attachment: DraftAttachment, staging: AttachmentStaging, scale: CGFloat) -> CGImage? {
        guard attachment.kind == .image, let url = staging.url(for: attachment) else { return nil }
        return PhotoNormalizer.thumbnail(url, maxPixel: Int(64 * max(2, scale)))
    }
}
