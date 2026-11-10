// [device-access] The Photos side of Device Access: `photos.search` (PhotoKit's own predicate, `near` filtered by
// distance over a bounded newest-first window) and `photos.get` (one JPEG, fit and sized under PhotosAccess's limits).
// Never reads the whole library: a search stops once it has enough matches, `near` scans at most 2000 assets.

import Foundation
import Photos
import Synchronization
import UIKit

nonisolated enum PhotosLookup {
    /// Up to 2000 of the newest assets in range are scanned when `near` needs a distance check PhotoKit can't do itself.
    private static let nearScanLimit = 2000
    /// docs/device-access.md: a sent photo stays well under this.
    private static let jpegCeiling = 3 * 1024 * 1024

    @concurrent static func search(_ request: DeviceAccess.Request) async -> DeviceAccess.Answer {
        let plan = DeviceAccess.photoSearchPlan(request)
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = predicate(for: plan)
        options.fetchLimit = plan.near == nil ? plan.limit + 1 : nearScanLimit
        let result = PHAsset.fetchAssets(with: options)
        var matches: [DeviceAccess.PhotoSummary] = []
        var more = false
        result.enumerateObjects { asset, _, stop in
            if Task.isCancelled { stop.pointee = true; return }
            if let near = plan.near {
                guard let location = asset.location,
                      DeviceAccess.kmBetween(location.coordinate.latitude, location.coordinate.longitude, near.latitude, near.longitude) <= near.radiusKm
                else { return }
            }
            if matches.count == plan.limit { more = true; stop.pointee = true; return }
            matches.append(summary(for: asset))
        }
        return .list("photos", matches.map(\.wire), more: more)
    }

    @concurrent static func get(_ request: DeviceAccess.Request) async -> DeviceAccess.Answer {
        guard let plan = DeviceAccess.photoGetPlan(request) else { return .failed("A photo id is needed.") }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [plan.id], options: nil).firstObject else {
            return .failed("That photo can’t be found.")
        }
        guard !Task.isCancelled, let image = await image(for: asset, maxPixels: plan.maxPixels) else {
            return .failed("That photo couldn’t be opened.")
        }
        guard let data = jpegData(image) else { return .failed("That photo couldn’t be opened.") }
        let name = DeviceAccess.photoFileName(asset.creationDate ?? .now)
        return DeviceAccess.Answer(status: .done, result: ["photo": summary(for: asset).wire],
                                   file: .init(data: data, type: "image/jpeg", name: name))
    }

    // MARK: PhotoKit

    private static func predicate(for plan: DeviceAccess.PhotoSearchPlan) -> NSPredicate {
        var parts: [NSPredicate] = []
        if let start = plan.start { parts.append(NSPredicate(format: "creationDate >= %@", start as NSDate)) }
        if let end = plan.end { parts.append(NSPredicate(format: "creationDate <= %@", end as NSDate)) }
        if let favorites = plan.favorites { parts.append(NSPredicate(format: "favorite == %@", NSNumber(value: favorites))) }
        switch plan.media {
        case .photo:
            parts.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue))
            parts.append(NSPredicate(format: "NOT ((mediaSubtype & %d) != 0)",
                                     PHAssetMediaSubtype.photoScreenshot.rawValue | PHAssetMediaSubtype.photoLive.rawValue))
        case .video: parts.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))
        case .screenshot: parts.append(NSPredicate(format: "(mediaSubtype & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue))
        case .live: parts.append(NSPredicate(format: "(mediaSubtype & %d) != 0", PHAssetMediaSubtype.photoLive.rawValue))
        case .any: break
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    private static func summary(for asset: PHAsset) -> DeviceAccess.PhotoSummary {
        let isVideo = asset.mediaType == .video
        let isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
        let isLive = asset.mediaSubtypes.contains(.photoLive)
        let place = asset.location.map { (latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
        return DeviceAccess.PhotoSummary(id: asset.localIdentifier, date: asset.creationDate,
                                         kind: DeviceAccess.photoKind(isScreenshot: isScreenshot, isLive: isLive, isVideo: isVideo),
                                         width: asset.pixelWidth, height: asset.pixelHeight,
                                         durationS: (isVideo || isLive) && asset.duration > 0 ? asset.duration : nil,
                                         favorite: asset.isFavorite, place: place)
    }

    /// The full-size (or live) image, fit to `maxPixels`; a video asset gives its poster frame. Cancelling the
    /// surrounding task cancels PhotoKit's own request too.
    private static func image(for asset: PHAsset, maxPixels: Int) async -> UIImage? {
        let fitted = DeviceAccess.fittedPixelSize(width: asset.pixelWidth, height: asset.pixelHeight, longestSide: maxPixels)
        let targetSize = CGSize(width: fitted.width, height: fitted.height)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .exact
        let box = Mutex<PHImageRequestID?>(nil)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let id = PHImageManager.default().requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options) { image, _ in
                    continuation.resume(returning: image)
                }
                box.withLock { $0 = id }
            }
        } onCancel: {
            if let id = box.withLock({ $0 }) { PHImageManager.default().cancelImageRequest(id) }
        }
    }

    /// JPEG under `jpegCeiling`: lower quality first, then a smaller copy if that still isn't enough.
    private static func jpegData(_ image: UIImage) -> Data? {
        var quality = 0.85
        var data = image.jpegData(compressionQuality: quality)
        while let current = data, current.count > jpegCeiling, quality > 0.3 {
            quality -= 0.15
            data = image.jpegData(compressionQuality: quality)
        }
        guard let current = data, current.count > jpegCeiling else { return data }
        let scale = sqrt(Double(jpegCeiling) / Double(current.count))
        guard let smaller = resized(image, scale: scale) else { return data }
        return smaller.jpegData(compressionQuality: 0.7) ?? data
    }

    private static func resized(_ image: UIImage, scale: Double) -> UIImage? {
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        guard size.width >= 1, size.height >= 1 else { return nil }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}
