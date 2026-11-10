// [share] What a shared photo or video becomes before it leaves the phone (docs/spec/3x-share.md §7.6, D9).
// Port of build 240's PickedFiles.swift:193-233. No UIKit: ImageIO, CoreGraphics and AVFoundation only.

import Foundation
import ImageIO
import CoreGraphics
import AVFoundation
import UniformTypeIdentifiers

nonisolated enum ShareMedia {
    enum Failure: Error, Equatable {
        case unreadablePhoto
        /// A video whose location could not be removed is not sent (never with where it was filmed).
        case locationNotRemoved
    }

    /// The longest side a shared photo is sent at, and its JPEG quality.
    static let maxPixel = 3072
    static let quality = 0.85
    static let thumbnailPixel = 160

    /// A photo of any format ImageIO reads (HEIC, JPEG, PNG, GIF, RAW) as a JPEG of at most `maxPixel` on its long
    /// side, made by ImageIO from the file: the full-resolution bitmap is never decoded. Only pixels are written: none
    /// of the original's metadata (its GPS location, camera and capture details) reaches the gateway, and its
    /// orientation is applied to the pixels instead of carried as a tag. Transparent pixels go onto white (D9); an
    /// animated GIF becomes its first frame.
    ///
    /// A camera JPEG is read a strip at a time (`strips`), which keeps a 48-megapixel photo within the extension's
    /// memory; every other format goes through ImageIO's own thumbnail maker, as build 240 does.
    static func jpeg(at url: URL, maxPixel: Int = ShareMedia.maxPixel, quality: Double = ShareMedia.quality,
                     stripBytes: Int = ShareMedia.stripBytes) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw Failure.unreadablePhoto
        }
        return try jpeg(source, maxPixel: maxPixel, quality: quality, stripBytes: stripBytes)
    }

    /// The same for a picture that arrives as bytes instead of a file (an app handing over a PNG or a JPEG it holds).
    static func jpeg(data: Data, maxPixel: Int = ShareMedia.maxPixel, quality: Double = ShareMedia.quality,
                     stripBytes: Int = ShareMedia.stripBytes) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw Failure.unreadablePhoto
        }
        return try jpeg(source, maxPixel: maxPixel, quality: quality, stripBytes: stripBytes)
    }

    private static func jpeg(_ source: CGImageSource, maxPixel: Int, quality: Double, stripBytes: Int) throws -> Data {
        guard CGImageSourceGetCount(source) > 0 else { throw Failure.unreadablePhoto }
        if let data = strips(source, maxPixel: maxPixel, quality: quality, stripBytes: stripBytes) { return data }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel, kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Failure.unreadablePhoto }
        // No properties beyond the quality and the background: nothing of the original's metadata is written.
        return try encode(image, quality: quality, background: true)
    }

    /// A bitmap that is already the right size and the right way up (a picture drawn by `ShareItemLoader`), as a JPEG.
    static func jpeg(of image: CGImage, quality: Double = ShareMedia.quality) throws -> Data {
        try encode(image, quality: quality, background: true)
    }

    /// The decoded bytes one strip of a JPEG may take while it is drawn (8 MB: about 500 rows of a 12-megapixel photo).
    static let stripBytes = 8 * 1024 * 1024

    private static func encode(_ image: CGImage, quality: Double, background: Bool) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.unreadablePhoto
        }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if background { properties[kCGImageDestinationBackgroundColor] = CGColor(red: 1, green: 1, blue: 1, alpha: 1) }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length > 0 else { throw Failure.unreadablePhoto }
        return data as Data
    }

    /// A baseline JPEG, drawn into the one output bitmap in horizontal strips and encoded from that bitmap where it
    /// is. ImageIO decodes a JPEG's rows as they are asked for, so the memory in use is the output (28 MB at
    /// 3072 x 2304) plus one strip, whatever the photo's size: its thumbnail maker instead holds the half-size decode
    /// and the output together, and a 48-megapixel photo then costs about 100 MB of an extension's 120.
    /// Nil when the file is not a baseline JPEG or anything here fails: the caller then takes the other path.
    static func strips(_ source: CGImageSource, maxPixel: Int, quality: Double, stripBytes: Int) -> Data? {
        guard (CGImageSourceGetType(source) as String?) == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        // A progressive JPEG has no rows to read on their own: every strip would decode all of it.
        if let jfif = properties[kCGImagePropertyJFIFDictionary] as? [CFString: Any],
           (jfif[kCGImagePropertyJFIFIsProgressive] as? NSNumber)?.boolValue == true { return nil }
        let fullWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let fullHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard fullWidth > 0, fullHeight > 0, maxPixel > 0 else { return nil }
        // The decoder halves a JPEG for free: take the smallest half, quarter or eighth still at least as large as the result.
        var factor = 1
        while factor < 8, max(fullWidth, fullHeight) / (factor * 2) >= maxPixel { factor *= 2 }
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if factor > 1 { options[kCGImageSourceSubsampleFactor] = factor }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary), image.width > 0, image.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let scale = min(1, Double(maxPixel) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded())), height = max(1, Int((Double(image.height) * scale).rounded()))
        let turned = (5...8).contains(orientation)
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(data: nil, width: turned ? height : width, height: turned ? width : height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: info), let pixels = context.data else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.interpolationQuality = .high
        // The photo's orientation tag, applied to the pixels (the eight EXIF cases; `w` and `h` are the unturned size).
        let w = CGFloat(width), h = CGFloat(height)
        let turn: CGAffineTransform = switch orientation {
        case 2: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case 6: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 7: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: .identity
        }
        context.concatenate(turn)
        // Strips of whole output rows. Each is drawn from the source rows it needs plus a margin and clipped to the
        // strip, so every output pixel comes from the same mapping one single draw would use: no seams.
        let vertical = Double(height) / Double(image.height)
        let sourceRows = max(16, stripBytes / max(1, image.width * 4))
        let rows = max(1, Int(Double(sourceRows) * vertical)), margin = 4
        var top = 0
        while top < height {
            let bottom = min(height, top + rows)
            let drawn: Bool = autoreleasepool {
                let first = max(0, Int((Double(top) / vertical).rounded(.down)) - margin)
                let last = min(image.height, Int((Double(bottom) / vertical).rounded(.up)) + margin)
                guard last > first, let strip = image.cropping(to: CGRect(x: 0, y: first, width: image.width, height: last - first)) else { return false }
                context.saveGState()
                // Output rows count from the top; CoreGraphics counts from the bottom.
                context.clip(to: CGRect(x: 0, y: CGFloat(height - bottom), width: w, height: CGFloat(bottom - top)))
                context.draw(strip, in: CGRect(x: 0, y: CGFloat(Double(height) - Double(last) * vertical), width: w,
                                               height: CGFloat(Double(last - first) * vertical)))
                context.restoreGState()
                return true
            }
            guard drawn else { return nil }
            top = bottom
        }
        // The encoder reads the bitmap where it is (`makeImage()` would copy all 28 MB of it first).
        guard let provider = CGDataProvider(dataInfo: nil, data: pixels, size: context.bytesPerRow * context.height, releaseData: { _, _, _ in }),
              let result = CGImage(width: context.width, height: context.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: context.bytesPerRow, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        // `context` owns the pixels: it stays alive until the encoder has read them.
        return withExtendedLifetime(context) { try? encode(result, quality: quality, background: false) }
    }

    /// A small preview of a staged photo, made by ImageIO (never the full picture: the extension has about 120 MB).
    static func thumbnail(at url: URL, maxPixel: Int = ShareMedia.thumbnailPixel) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }

    /// A video leaves without where it was filmed: a passthrough re-mux (the streams are copied, never re-encoded)
    /// with AVFoundation's sharing metadata filter, in place of the copy. A video that cannot be re-muxed throws
    /// (it is then not sent at all).
    static func removeLocation(fromMovieAt url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw Failure.locationNotRemoved
        }
        let ext = url.pathExtension.lowercased()
        let type: AVFileType = switch ext {
        case "mp4": .mp4
        case "m4v": .m4v
        default: .mov
        }
        let output = url.deletingLastPathComponent()
            .appendingPathComponent(".sharing-" + UUID().uuidString + "." + (ext.isEmpty ? "mov" : ext))
        export.metadataItemFilter = .forSharing()
        do {
            try await export.export(to: output, as: type)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: output)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw Failure.locationNotRemoved
        }
    }
}
