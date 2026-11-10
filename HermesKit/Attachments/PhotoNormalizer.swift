// Photos as the gateway gets them (docs/spec/1x-attachments.md §5.1–§5.2; R:ios/App/App/PickedFiles.swift:188-205):
// at most 3072 px on the long side, orientation applied to the pixels, JPEG 0.85 (PNG when it has real transparency,
// an animated GIF unchanged), and no metadata at all — no EXIF, GPS, TIFF or maker data. The full-resolution bitmap
// is never decoded (ImageIO thumbnails from the file). Pure and `nonisolated`; call it off the main thread.

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import Synchronization

nonisolated enum PhotoNormalizer {
    static let maxPixel = 3072
    static let quality = 0.85

    struct Output: Sendable, Equatable {
        var url: URL
        var name: String
        var pixelWidth: Int
        var pixelHeight: Int
        var typeIdentifier: String
        var byteSize: Int64
    }

    /// Whether ImageIO can open `url` as an image (an image picked from Files goes the photo path, A3).
    static func canNormalize(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0, let type = CGImageSourceGetType(source) as String?,
              let ut = UTType(type), ut.conforms(to: .image) else { return false }
        // SVG and PDF are not ImageIO raster images; anything else ImageIO decodes is.
        return !ut.conforms(to: .svg) && !ut.conforms(to: .pdf)
    }

    /// Writes the normalised copy of `source` as `<stem>.<ext>` into `folder` and returns it.
    static func normalize(_ source: URL, stem: String, into folder: URL) throws -> Output {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(image) > 0 else { throw AttachmentPrepareError.unreadablePhoto }
        let type = CGImageSourceGetType(image) as String? ?? ""
        let frames = CGImageSourceGetCount(image)
        let size = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let safeStem = AttachmentStaging.stem(AttachmentStaging.safeName(stem + ".x"))

        // An animated GIF keeps its animation: copied unchanged (still within the attachment limit).
        if type == UTType.gif.identifier && frames > 1 {
            guard size <= AttachmentStaging.maxItemBytes else { throw AttachmentPrepareError.tooLarge(name: safeStem + ".gif") }
            let name = safeStem + ".gif"
            let target = folder.appending(path: name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: target.path)
            let (w, h) = pixelSize(of: target) ?? (0, 0)
            return Output(url: target, name: name, pixelWidth: w, pixelHeight: h, typeIdentifier: UTType.gif.identifier, byteSize: size)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let pixels = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary) else {
            throw AttachmentPrepareError.unreadablePhoto
        }
        let png = hasTransparency(pixels)
        let ut = png ? UTType.png : UTType.jpeg
        let name = safeStem + (png ? ".png" : ".jpg")
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, ut.identifier as CFString, 1, nil) else {
            throw AttachmentPrepareError.unreadablePhoto
        }
        // No properties dictionary beyond the quality: nothing of the original's metadata is written.
        CGImageDestinationAddImage(destination, pixels, png ? nil : [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AttachmentPrepareError.unreadablePhoto }
        guard Int64(data.length) <= AttachmentStaging.maxItemBytes else { throw AttachmentPrepareError.tooLarge(name: name) }
        let target = folder.appending(path: name)
        try (data as Data).write(to: target, options: [.atomic, .completeFileProtectionUnlessOpen])
        return Output(url: target, name: name, pixelWidth: pixels.width, pixelHeight: pixels.height, typeIdentifier: ut.identifier,
                      byteSize: Int64(data.length))
    }

    /// A camera photo (`UIImage` → CGImage already oriented by the caller): ≤ 3072 px, JPEG 0.85, no metadata.
    static func encodeJPEG(_ pixels: CGImage, into folder: URL, name: String) throws -> Output {
        var image = pixels
        if max(image.width, image.height) > maxPixel, let scaled = downscale(image, maxPixel: maxPixel) { image = scaled }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AttachmentPrepareError.cameraNotSaved
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AttachmentPrepareError.cameraNotSaved }
        let target = folder.appending(path: name)
        try (data as Data).write(to: target, options: [.atomic, .completeFileProtectionUnlessOpen])
        return Output(url: target, name: name, pixelWidth: image.width, pixelHeight: image.height, typeIdentifier: UTType.jpeg.identifier,
                      byteSize: Int64(data.length))
    }

    /// The tile thumbnail (spec §5.2) or any bucketed display image: ImageIO from the file, oriented.
    static func thumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(source, maxPixel: maxPixel)
    }

    static func thumbnail(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(source, maxPixel: maxPixel)
    }

    private static func thumbnail(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(16, maxPixel),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Displayed pixel size (orientation applied) from the header only (spec §8.3).
    static func pixelSize(of url: URL) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return pixelSize(source)
    }

    static func pixelSize(of data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return pixelSize(source)
    }

    private static func pixelSize(_ source: CGImageSource) -> (Int, Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 && orientation <= 8 ? (h, w) : (w, h)
    }

    /// Real transparency: an alpha channel *and* a pixel with alpha < 255 (sampled on a 64 × 64 downscale).
    static func hasTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let side = 64
        var buffer = [UInt8](repeating: 255, count: side * side * 4)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.clear(CGRect(x: 0, y: 0, width: side, height: side))
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return false }
        var i = 3
        while i < buffer.count {
            if buffer[i] < 255 { return true }
            i += 4
        }
        return false
    }

    private static func downscale(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let scale = Double(maxPixel) / Double(max(image.width, image.height))
        let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }
}

/// [perf] At most two photo normalizes at once, app-wide. Each is a 3072-px decode plus an encode (a 48 MP photo
/// ~100 MB), and a pick of 8 ran all of them together; uploads go one at a time anyway. It blocks the calling thread,
/// so call it only on a GCD thread (a provider callback, a global queue), never on the Swift concurrency pool.
/// Two locks rather than a semaphore: a lock's owner inherits a waiter's priority, a semaphore's holder doesn't.
nonisolated enum PhotoPrepGate {
    private static let slots = [NSLock(), NSLock()]
    private static let turn = Atomic<UInt>(0)

    static func run<T>(_ body: () throws -> T) rethrows -> T {
        let slot = slots.first { $0.try() } ?? {
            let l = slots[Int(turn.wrappingAdd(1, ordering: .relaxed).oldValue % UInt(slots.count))]
            l.lock()
            return l
        }()
        defer { slot.unlock() }
        #if DEBUG
        debugInFlight.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) }
        defer { debugInFlight.withLock { $0.now -= 1 } }
        #endif
        return try body()
    }

    #if DEBUG
    /// Tests: how many run at once now, and the most seen.
    static let debugInFlight = Mutex<(now: Int, peak: Int)>((0, 0))
    #endif
}
