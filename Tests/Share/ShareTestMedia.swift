// [share] Invented media for the Share extension's unit tests: small photos with location and camera details, a
// transparent picture, a one-second video that says where it was filmed, and a way to watch memory.

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import HermesHQNative

nonisolated enum ShareTestMedia {
    static let location = "+37.3349-122.0090+010.000/"

    static func bitmap(width: Int, height: Int, alpha: Bool = false, draw: (CGContext) -> Void) -> CGImage {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
        draw(context)
        return context.makeImage()!
    }

    /// Left half red, right half blue, a green bar along the top: enough to tell which way up a picture ended.
    static func marked(width: Int, height: Int) -> CGImage {
        bitmap(width: width, height: height) { context in
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
            context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: height - height / 8, width: width, height: height / 8))      // CG's origin is bottom-left
        }
    }

    static var gps: [CFString: Any] {
        [kCGImagePropertyGPSLatitude: 37.3349, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 122.009, kCGImagePropertyGPSLongitudeRef: "W"]
    }
    static var camera: [CFString: Any] {
        [kCGImagePropertyGPSDictionary: gps,
         kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "FixtureCam", kCGImagePropertyTIFFModel: "Model One"],
         kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:10 09:00:00", kCGImagePropertyExifLensModel: "Fixture Lens"]]
    }

    static func encode(_ image: CGImage, as type: UTType, properties: [CFString: Any] = [:]) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// A small JPEG with GPS, a camera make and a capture date.
    @discardableResult
    static func photo(_ name: String, in folder: URL, width: Int = 96, height: Int = 64, orientation: Int? = nil) -> URL {
        var properties = camera
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        let url = folder.appendingPathComponent(name)
        try? encode(marked(width: width, height: height), as: .jpeg, properties: properties).write(to: url)
        return url
    }

    static func properties(of data: Data) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [:] }
        return (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
    }

    static func frames(of data: Data) -> Int { CGImageSourceCreateWithData(data as CFData, nil).map(CGImageSourceGetCount) ?? 0 }
    static func type(of data: Data) -> String? { CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) as String? } }

    /// The picture's pixels as RGBA, top row first.
    static func pixels(of data: Data) -> (width: Int, height: Int, rgba: [UInt8])? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? (image.width, image.height, bytes) : nil
    }

    static func colour(_ picture: (width: Int, height: Int, rgba: [UInt8]), x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let at = (y * picture.width + x) * 4
        return (Int(picture.rgba[at]), Int(picture.rgba[at + 1]), Int(picture.rgba[at + 2]))
    }

    /// Nothing of the original's metadata: no location, no camera, no capture details, upright without a tag.
    static func carriesNothing(_ data: Data) -> Bool {
        let all = properties(of: data)
        guard all[kCGImagePropertyGPSDictionary] == nil else { return false }
        let tiff = all[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        for key in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware, kCGImagePropertyTIFFDateTime,
                    kCGImagePropertyTIFFArtist] where tiff[key] != nil { return false }
        let exif = all[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        // ImageIO reports a JPEG's size (and colour space) under Exif even when the file holds none.
        let harmless: Set<String> = [kCGImagePropertyExifPixelXDimension as String, kCGImagePropertyExifPixelYDimension as String,
                                     kCGImagePropertyExifColorSpace as String]
        guard exif.keys.allSatisfy({ harmless.contains($0 as String) }) else { return false }
        let orientation = (all[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard orientation == 1 else { return false }
        for word in ["FixtureCam", "Fixture Lens", "2026:10:10", "Apple", "iPhone"] where data.range(of: Data(word.utf8)) != nil { return false }
        return true
    }

    // MARK: Video

    nonisolated struct MovieFailure: Error { let what: String }

    /// One second of 320×240 H.264, saying where it was filmed when `location` is given.
    static func movie(at url: URL, location: String? = ShareTestMedia.location, seconds: Int = 1) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA), kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240,
        ])
        if let location {
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = AVMetadataKey.quickTimeMetadataKeyLocationISO6709.rawValue as NSString
            item.identifier = .quickTimeMetadataLocationISO6709
            item.value = location as NSString
            item.dataType = kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709 as String
            writer.metadata = [item]
        }
        guard writer.canAdd(input) else { throw MovieFailure(what: "input") }
        writer.add(input)
        guard writer.startWriting() else { throw MovieFailure(what: "start: \(String(describing: writer.error))") }
        writer.startSession(atSourceTime: .zero)
        let frames = seconds * 30
        for frame in 0..<frames {
            var waited = 0
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
                waited += 1
                if waited > 4000 { throw MovieFailure(what: "encoder never ready") }
            }
            var made: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let buffer = made else {
                throw MovieFailure(what: "buffer")
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(40 + frame * 6 % 200), CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)) else {
                throw MovieFailure(what: "append: \(String(describing: writer.error))")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: 30))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw MovieFailure(what: "finish: \(String(describing: writer.error))") }
    }

    /// What the video says about where it was filmed: every metadata value of any format that names a location, and
    /// whether the file's bytes hold an ISO 6709 string at all (the stand-in gateway's own check).
    static func locations(inMovieAt url: URL) async throws -> [String] {
        let asset = AVURLAsset(url: url)
        var found: [String] = []
        for format in try await asset.load(.availableMetadataFormats) {
            for item in try await asset.loadMetadata(for: format) {
                let name = (item.identifier?.rawValue ?? "") + "|" + (item.commonKey?.rawValue ?? "")
                guard name.localizedCaseInsensitiveContains("location") else { continue }
                found.append((try? await item.load(.stringValue)) ?? name)
            }
        }
        if let bytes = try? Data(contentsOf: url), bytes.range(of: Data("+37.3349-122.0090".utf8)) != nil { found.append("bytes") }
        return found
    }

    static func facts(ofMovieAt url: URL) async throws -> (seconds: Double, playable: Bool, videoTracks: Int) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let playable = try await asset.load(.isPlayable)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        return (duration.seconds, playable, tracks.count)
    }

    // MARK: Memory

    /// This process's memory footprint in bytes (what iOS counts against an extension's limit).
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    /// The most the footprint grew above where it started while `work` ran (sampled every 2 ms on another thread).
    static func peakGrowth<T>(_ work: () throws -> T) rethrows -> (value: T, bytes: Int) {
        let start = footprint()
        let peak = Peak(start)
        let sampler = Thread { while !Thread.current.isCancelled { peak.see(footprint()); usleep(2000) } }
        sampler.start()
        defer { sampler.cancel() }
        let value = try work()
        peak.see(footprint())
        return (value, peak.value - start)
    }

    private nonisolated final class Peak: @unchecked Sendable {
        private let lock = NSLock()
        private var most: Int
        init(_ start: Int) { most = start }
        func see(_ value: Int) { lock.withLock { most = max(most, value) } }
        var value: Int { lock.withLock { most } }
    }
}

/// Counts how often an item provider was asked for its file.
nonisolated final class LoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func hit(_ name: String) { lock.withLock { counts[name, default: 0] += 1 } }
    func count(_ name: String) -> Int { lock.withLock { counts[name] ?? 0 } }
    var total: Int { lock.withLock { counts.values.reduce(0, +) } }
}

nonisolated enum ShareProviders {
    /// A provider that hands over `file` as `type` (as another app's share does), counting each load.
    static func file(_ file: URL, type: UTType, name: String? = nil, counter: LoadCounter? = nil) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = name
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            counter?.hit(name ?? file.lastPathComponent)
            completion(file, false, nil)
            return nil
        }
        return provider
    }

    static func item(_ providers: [NSItemProvider], caption: String? = nil) -> NSExtensionItem {
        let item = NSExtensionItem()
        item.attachments = providers
        if let caption { item.attributedContentText = NSAttributedString(string: caption) }
        return item
    }
}
